import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// One terminal-output chunk waiting to be applied by a mounted mobile surface.
struct TerminalOutputDelivery: Equatable, Sendable {
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

    var replaceable: Bool {
        replacementScope != nil
    }

    init(
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        endSequence: UInt64? = nil
    ) {
        self.payload = .bytes(bytes)
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.endSequence = endSequence
    }

    init(theme frame: MobileTerminalRenderGridFrame) {
        self.payload = .theme(frame)
        self.replacementScope = .terminalTheme
        self.viewportPolicy = nil
        self.endSequence = nil
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
    /// Pending-depth cap for one surface's backlog. Raw byte chunks are
    /// nonreplaceable, so a consumer that stops acking (wedged worker, a
    /// surface stuck applying) lets live output grow the pending array without
    /// bound and each chunk retains its full byte payload — a jetsam
    /// contributor on low-RAM devices. The cap is generous (hundreds, far past
    /// any healthy apply backlog) because the recovery — drop the backlog and
    /// request an authoritative replay — is itself expensive; breaching it
    /// must mean the backlog will never drain, not that output is bursty.
    static let maxPendingDepthBeforeReplayReset = 512

    private var inFlight = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0

    var isIdle: Bool {
        !inFlight && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    mutating func enqueue(_ delivery: TerminalOutputDelivery) -> TerminalOutputDelivery? {
        guard inFlight else {
            inFlight = true
            return delivery
        }
        appendPending(delivery)
        return nil
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
