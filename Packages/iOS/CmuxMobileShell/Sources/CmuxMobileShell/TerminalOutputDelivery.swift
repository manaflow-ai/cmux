import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
    /// Selects how a byte delivery is admitted to the mounted terminal.
    ///
    /// `automatic` derives the verified-replay requirement from the negotiated
    /// transport. `bestEffortCompatibility` is reserved for the bounded
    /// retry-exhaustion replacement, whose payload is intentionally unverified
    /// but still must be applied so the barrier can release.
    enum ReplayVerificationPolicy: Equatable, Sendable {
        case automatic
        case bestEffortCompatibility
    }

    enum ReplacementScope: Equatable, Sendable {
        case byteViewport
        case renderGridViewport
        case terminalTheme
        case viewportPolicy
    }

    private enum Payload: Equatable, Sendable {
        case bytes(Data)
        case renderGrid(MobileTerminalRenderGridFrame)
        case theme(MobileTerminalRenderGridFrame)
    }

    private var payload: Payload
    var replacementScope: ReplacementScope?
    var viewportPolicy: MobileTerminalOutputViewportPolicy?
    var endSequence: UInt64?
    var replayVerificationPolicy: ReplayVerificationPolicy

    var replaceable: Bool {
        replacementScope != nil
    }

    /// Compatibility replacements must reset the consumer's verified replay
    /// baseline before their bytes are applied through the legacy path.
    var requiresVerifiedReplayReset: Bool {
        replayVerificationPolicy == .bestEffortCompatibility
    }

    init(
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        endSequence: UInt64? = nil,
        replayVerificationPolicy: ReplayVerificationPolicy = .automatic
    ) {
        self.payload = .bytes(bytes)
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.endSequence = endSequence
        self.replayVerificationPolicy = replayVerificationPolicy
    }

    init(theme frame: MobileTerminalRenderGridFrame) {
        self.payload = .theme(frame)
        self.replacementScope = .terminalTheme
        self.viewportPolicy = nil
        self.endSequence = nil
        self.replayVerificationPolicy = .automatic
    }

    init(
        renderGrid frame: MobileTerminalRenderGridFrame,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil
    ) {
        self.payload = .renderGrid(frame)
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.endSequence = frame.stateSeq
        self.replayVerificationPolicy = .automatic
    }

    var bytes: Data {
        switch payload {
        case .bytes(let bytes):
            bytes
        case .renderGrid(let frame):
            frame.vtPatchBytes()
        case .theme(let frame):
            MobileTerminalRenderGridReplay(frame).themePatchBytes()
        }
    }

    var terminalConfigTheme: TerminalTheme? {
        switch payload {
        case .renderGrid(let frame), .theme(let frame):
            frame.terminalConfigTheme
        case .bytes:
            nil
        }
    }

    var sourceRenderGridFrame: MobileTerminalRenderGridFrame? {
        guard case .renderGrid(let frame) = payload else { return nil }
        return frame
    }
}

/// Backpressure queue for one mounted mobile terminal output stream.
///
/// Raw byte chunks are nonreplaceable barriers. Render-grid chunks that repaint
/// the whole viewport are replaceable while the iOS surface is still applying a
/// prior chunk, so fast scroll gestures can skip obsolete intermediate frames.
struct TerminalOutputDeliveryQueue: Sendable {
    enum EnqueueResult: Equatable, Sendable {
        case immediate(TerminalOutputDelivery)
        case queued
        case overloaded
    }

    /// A stalled surface must not retain an unbounded sequence of
    /// nonreplaceable deltas. Once this many applies are waiting, the caller
    /// replaces the queue with an authoritative replay instead of adding more
    /// work that is already becoming stale.
    static let maximumPendingCount = 32

    private var inFlight = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0

    var isIdle: Bool {
        !inFlight && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> EnqueueResult {
        guard inFlight else {
            inFlight = true
            return .immediate(delivery)
        }
        appendPending(delivery)
        guard pendingCount <= Self.maximumPendingCount else {
            reset()
            return .overloaded
        }
        return .queued
    }

    mutating func completeInFlight() -> TerminalOutputDelivery? {
        guard inFlight else {
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return nil
        }
        guard pendingHeadIndex < pending.count else {
            inFlight = false
            pending.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            return nil
        }
        let next = pending[pendingHeadIndex]
        pendingHeadIndex += 1
        compactPendingStorageIfNeeded()
        return next
    }

    mutating func reset() {
        inFlight = false
        pending.removeAll(keepingCapacity: false)
        pendingHeadIndex = 0
    }

    private mutating func appendPending(_ delivery: TerminalOutputDelivery) {
        guard let replacementScope = delivery.replacementScope else {
            pending.append(delivery)
            return
        }
        var candidateIndex = pending.count
        while candidateIndex > pendingHeadIndex {
            candidateIndex -= 1
            guard pending[candidateIndex].replaceable else { break }
            if pending[candidateIndex].replacementScope == replacementScope {
                pending.remove(at: candidateIndex)
                break
            }
        }
        pending.append(delivery)
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHeadIndex > 32, pendingHeadIndex * 2 >= pending.count else { return }
        pending.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }
}
