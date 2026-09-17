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

    let receivedAtNanos = DispatchTime.now().uptimeNanoseconds

    private var payload: Payload
    var replacementScope: ReplacementScope?
    var viewportPolicy: MobileTerminalOutputViewportPolicy?
    var endSequence: UInt64?
    /// Whether this delivery was admitted to the verified replay path. This
    /// decision is captured before delivery advances render-grid continuity;
    /// queued chunks must retain the admission result until they are yielded.
    let requiresVerifiedReplay: Bool

    var replaceable: Bool {
        replacementScope != nil
    }

    /// A revisioned render-grid delta is tied to the exact frame named by its
    /// base revision. Replacing an older pending delta with a newer one would
    /// drop that base and make the newer patch paint against the wrong grid.
    /// Legacy frames without revision metadata retain the old coalescing rule.
    var canCoalesce: Bool {
        guard replaceable else { return false }
        guard case .renderGrid(let frame) = payload else { return true }
        return frame.deltaBaseRenderRevision == nil
            && frame.deltaBaseHistoryRows == nil
            && frame.scrolledRows == 0
    }

    init(
        bytes: Data,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        endSequence: UInt64? = nil,
        requiresVerifiedReplay: Bool = false
    ) {
        self.payload = .bytes(bytes)
        self.replacementScope = replaceable ? (replacementScope ?? .byteViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.endSequence = endSequence
        self.requiresVerifiedReplay = requiresVerifiedReplay
    }

    init(
        theme frame: MobileTerminalRenderGridFrame,
        requiresVerifiedReplay: Bool = false
    ) {
        self.payload = .theme(frame)
        self.replacementScope = .terminalTheme
        self.viewportPolicy = nil
        self.endSequence = nil
        self.requiresVerifiedReplay = requiresVerifiedReplay
    }

    init(
        renderGrid frame: MobileTerminalRenderGridFrame,
        replaceable: Bool,
        replacementScope: ReplacementScope? = nil,
        viewportPolicy: MobileTerminalOutputViewportPolicy? = nil,
        requiresVerifiedReplay: Bool = false
    ) {
        self.payload = .renderGrid(frame)
        self.replacementScope = replaceable ? (replacementScope ?? .renderGridViewport) : nil
        self.viewportPolicy = viewportPolicy
        self.endSequence = frame.stateSeq
        self.requiresVerifiedReplay = requiresVerifiedReplay
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payload == rhs.payload && lhs.replacementScope == rhs.replacementScope
            && lhs.viewportPolicy == rhs.viewportPolicy && lhs.endSequence == rhs.endSequence
            && lhs.requiresVerifiedReplay == rhs.requiresVerifiedReplay
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
    static let maxPendingDeliveries = 128
    private var inFlight = false
    private var pending: [TerminalOutputDelivery] = []
    private var pendingHeadIndex = 0
    private var overflowed = false

    var isIdle: Bool {
        !inFlight && pendingCount == 0
    }

    var pendingCount: Int {
        pending.count - pendingHeadIndex
    }

    mutating func takeOverflowed() -> Bool {
        defer { overflowed = false }
        return overflowed
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
        overflowed = false
    }

    private mutating func appendPending(_ delivery: TerminalOutputDelivery) {
        guard let replacementScope = delivery.replacementScope else {
            guard pendingCount < Self.maxPendingDeliveries else {
                overflowed = true
                pending.removeAll(keepingCapacity: false)
                pendingHeadIndex = 0
                return
            }
            pending.append(delivery)
            return
        }
        guard delivery.canCoalesce else {
            guard pendingCount < Self.maxPendingDeliveries else {
                overflowed = true
                pending.removeAll(keepingCapacity: false)
                pendingHeadIndex = 0
                return
            }
            pending.append(delivery)
            return
        }
        var candidateIndex = pending.count
        while candidateIndex > pendingHeadIndex {
            candidateIndex -= 1
            guard pending[candidateIndex].canCoalesce else { break }
            if pending[candidateIndex].replacementScope == replacementScope {
                pending.remove(at: candidateIndex)
                break
            }
        }
        guard pendingCount < Self.maxPendingDeliveries else {
            overflowed = true
            pending.removeAll(keepingCapacity: false)
            pendingHeadIndex = 0
            return
        }
        pending.append(delivery)
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHeadIndex > 32, pendingHeadIndex * 2 >= pending.count else { return }
        pending.removeFirst(pendingHeadIndex)
        pendingHeadIndex = 0
    }
}
