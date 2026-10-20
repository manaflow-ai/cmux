#if canImport(UIKit)
import CMUXMobileCore
import Observation

/// Owns bounded Simulator frame decoding for one mounted stream pane.
@MainActor
@Observable
final class SimulatorFramePresentationPipeline<Presented: Sendable> {
    struct Presentation: Sendable {
        let frame: MobileSimulatorFrameEvent
        let value: Presented
    }

    struct Progress: Equatable, Sendable {
        var panelID: String?
        var receivedSequence: UInt64?
        var activeSequence: UInt64?
        var pendingSequence: UInt64?
        var presentedSequence: UInt64?
        var failedSequence: UInt64?
        var consecutiveFailureCount = 0
    }

    enum Event: Sendable {
        case presented(MobileSimulatorFrameEvent)
        case decodeFailed(MobileSimulatorFrameEvent)
        case discarded(MobileSimulatorFrameEvent)
        case presentationStalled(MobileSimulatorFrameEvent)
    }

    private let decoder: @Sendable (MobileSimulatorFrameEvent) async -> Presented?
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var decodeTask: Task<Void, Never>?
    private var pendingFrame: MobileSimulatorFrameEvent?
    private var generation: UInt64 = 0

    let events: AsyncStream<Event>
    private(set) var presented: Presentation?
    private(set) var progress = Progress()

    init(decoder: @escaping @Sendable (MobileSimulatorFrameEvent) async -> Presented?) {
        let (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
        self.decoder = decoder
        self.events = events
        self.eventContinuation = eventContinuation
    }

    /// Accepts the newest absolute frame while keeping at most one decode
    /// active and one replaceable frame waiting behind it.
    func submit(_ frame: MobileSimulatorFrameEvent, allowDuplicateSequence: Bool = false) {
        if progress.panelID != frame.panelID {
            generation &+= 1
            progress = Progress(panelID: frame.panelID, receivedSequence: frame.sequence)
            presented = nil
            pendingFrame = frame
            progress.pendingSequence = frame.sequence
            decodeTask?.cancel()
        } else {
            let isNewerSequence = progress.receivedSequence.map { frame.sequence > $0 } ?? true
            guard allowDuplicateSequence || isNewerSequence else { return }
            progress.receivedSequence = frame.sequence
            pendingFrame = frame
            progress.pendingSequence = frame.sequence
        }
        startPendingDecodeIfPossible()
    }

    /// Ends this pane's presentation lifecycle. A decoder that does not
    /// promptly honor cancellation is still fenced from publishing an image.
    func cancel() {
        generation &+= 1
        pendingFrame = nil
        progress = Progress()
        presented = nil
        decodeTask?.cancel()
    }

    private func startPendingDecodeIfPossible() {
        guard decodeTask == nil, let frame = pendingFrame else { return }
        pendingFrame = nil
        progress.activeSequence = frame.sequence
        progress.pendingSequence = nil
        let decodeGeneration = generation
        let decoder = decoder
        decodeTask = Task { [weak self] in
            let decoded = await decoder(frame)
            self?.completeDecode(
                frame: frame,
                decoded: decoded,
                generation: decodeGeneration,
                wasCancelled: Task.isCancelled
            )
        }
    }

    private func completeDecode(
        frame: MobileSimulatorFrameEvent,
        decoded: Presented?,
        generation decodeGeneration: UInt64,
        wasCancelled: Bool
    ) {
        decodeTask = nil
        progress.activeSequence = nil
        if decodeGeneration == generation, !wasCancelled {
            if let decoded {
                presented = Presentation(frame: frame, value: decoded)
                progress.presentedSequence = frame.sequence
                progress.failedSequence = nil
                progress.consecutiveFailureCount = 0
                eventContinuation.yield(.presented(frame))
            } else {
                progress.failedSequence = frame.sequence
                progress.consecutiveFailureCount += 1
                eventContinuation.yield(.decodeFailed(frame))
                if progress.consecutiveFailureCount == 3 {
                    eventContinuation.yield(.presentationStalled(frame))
                    progress.consecutiveFailureCount = 0
                }
            }
        } else {
            eventContinuation.yield(.discarded(frame))
        }
        startPendingDecodeIfPossible()
    }
}
#endif
