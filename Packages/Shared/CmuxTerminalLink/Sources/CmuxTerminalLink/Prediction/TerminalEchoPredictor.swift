public import Foundation

/// Speculative local echo over a `.host` mirror (c1-terminal-rpc.md
/// section 8). A value: the source feeds it inputs and host frames in order.
///
/// Predicted bytes sit at host offsets right after the last host byte the
/// phone has seen. Shown predictions are emitted as synthesized `bytes`
/// frames, so the viewer's offset moves past them and the host's matching
/// echo is dropped as already applied. Shadow predictions (not yet
/// confident) are only checked, to earn confidence.
public struct TerminalEchoPredictor: Sendable {
    public let options: TerminalPredictionOptions
    /// The host offset after the last real byte seen (READY or bytes).
    public private(set) var hostOffset: UInt64?
    public private(set) var generation: UInt32?
    /// Bytes expected next from the host, starting at `hostOffset`.
    public private(set) var pending = Data()
    /// Whether `pending` was shown (all of it or none).
    public private(set) var pendingShown = false
    /// When the oldest pending byte was typed.
    public private(set) var pendingSince: Duration?
    public private(set) var confirmations = 0
    /// After a non-printable input: no more appends until `pending` drains.
    private var acceptingAppends = true

    public init(options: TerminalPredictionOptions) {
        self.options = options
    }

    /// The offset the viewer holds: host bytes plus shown predictions.
    public var viewerOffset: UInt64? {
        hostOffset.map { $0 + (pendingShown ? UInt64(pending.count) : 0) }
    }

    /// A READY restored the host's screen: every prediction is void.
    public mutating func restored(generation: UInt32, offset: UInt64) {
        self.generation = generation
        hostOffset = offset
        clearPending()
        acceptingAppends = true
    }

    /// The source stopped following (resync pending, reattach): forget the
    /// mirror until the next READY.
    public mutating func suspend() {
        hostOffset = nil
        generation = nil
        clearPending()
        confirmations = 0
    }

    /// One input write. Returns the bytes to show now, or nil.
    public mutating func input(_ data: Data, rtt: Duration?, now: Duration) -> Data? {
        guard options.enabled, hostOffset != nil else { return nil }
        if let since = pendingSince, !pendingShown, now - since > expiry(rtt: rtt) {
            // A shadow prediction never echoed (no echo, or output in between).
            clearPending()
            confirmations = 0
        }
        guard Self.isPrintable(data) else {
            confirmations = 0
            if pending.isEmpty { acceptingAppends = true } else { acceptingAppends = false }
            return nil
        }
        guard acceptingAppends else { return nil }
        if pending.isEmpty {
            pendingShown = confident(rtt: rtt)
            pendingSince = now
        }
        pending.append(data)
        return pendingShown ? data : nil
    }

    /// A host `bytes` frame, before it is forwarded. `frame.offset` is the
    /// host offset after its payload.
    public mutating func reconcile(generation frameGeneration: UInt32, offset end: UInt64, payload: Data) -> TerminalPredictionVerdict {
        guard let hostOffset else { return .none }
        let start = end >= UInt64(payload.count) ? end - UInt64(payload.count) : 0
        defer {
            if end > (self.hostOffset ?? 0) { self.hostOffset = end }
            if pending.isEmpty { acceptingAppends = true }
        }
        if frameGeneration != generation {
            // A grid change: the viewer resyncs to the new generation's READY,
            // which replaces any shown prediction; nothing to compare.
            return clearShadow()
        }
        guard !pending.isEmpty, end > hostOffset else { return .none }
        // The frame's bytes past what the phone already had, compared with
        // the predicted run from its start.
        let fresh = payload.suffix(Int(end - max(start, hostOffset)))
        guard start <= hostOffset else {
            // Bytes before the predicted run were lost: the viewer resyncs.
            return pendingShown ? .rollback : clearShadow()
        }
        let count = min(fresh.count, pending.count)
        guard fresh.prefix(count).elementsEqual(pending.prefix(count)) else {
            if pendingShown { return .rollback }
            return clearShadow()
        }
        pending.removeFirst(count)
        confirmations += 1
        if pending.isEmpty {
            pendingSince = nil
        }
        return .confirmed(count)
    }

    /// The expiry for the oldest shown prediction, or nil when none is shown.
    public func shownDeadline(rtt: Duration?) -> Duration? {
        guard pendingShown, !pending.isEmpty, let pendingSince else { return nil }
        return pendingSince + expiry(rtt: rtt)
    }

    public func expiry(rtt: Duration?) -> Duration {
        max(options.minimumExpiry, (rtt ?? .zero) * 3)
    }

    private func confident(rtt: Duration?) -> Bool {
        guard let rtt, rtt >= options.minimumRTT else { return false }
        return confirmations >= options.confirmationsToPredict
    }

    private mutating func clearShadow() -> TerminalPredictionVerdict {
        clearPending()
        confirmations = 0
        return .none
    }

    private mutating func clearPending() {
        pending.removeAll()
        pendingShown = false
        pendingSince = nil
    }

    /// Printable ASCII only: anything else (Enter, control keys, escape
    /// sequences, multibyte text) echoes in ways the phone cannot know.
    static func isPrintable(_ data: Data) -> Bool {
        !data.isEmpty && data.allSatisfy { (0x20...0x7e).contains($0) }
    }
}
