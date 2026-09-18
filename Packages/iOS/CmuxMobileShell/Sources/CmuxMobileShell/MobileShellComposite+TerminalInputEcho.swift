internal import Foundation

/// One marked terminal input awaiting its accepted-input watermark echo.
struct PendingTerminalInputEcho: Sendable {
    let sequence: UInt64
    let sentAt: Date
}

// MARK: - Input-echo liveness evidence
//
// Marked terminal input (the `terminal.input.latency.v1` watermark contract)
// gives the render-grid liveness watchdog something ambient silence cannot:
// positive proof that the terminal is NOT idle. A marked input the host
// accepted must eventually be acknowledged by a delivered output frame's
// cumulative `applied_input_sequence` watermark. When that echo is missing
// past `terminalInputEchoStallThreshold` and nothing has been consumed from
// the event stream since the input was dispatched, the output path is stalled
// from the user's point of view, whatever the control channel says.
//
// The watchdog uses that evidence in three places:
// - it probes immediately instead of waiting out the 9s ambient window;
// - a SUCCESSFUL probe no longer pacifies it (issue 10471: healthy control
//   channel, dead event lane) — it repairs the output path instead;
// - a FAILED probe escalates without the second confirmation failure.
extension MobileShellComposite {
    /// Mints the next session-randomized increasing wire marker.
    func mintTerminalInputMarkerSequence() -> UInt64 {
        nextTerminalInputMarkerSequence &+= 1
        return nextTerminalInputMarkerSequence
    }

    /// Records a successfully dispatched marked input as awaiting its echo.
    ///
    /// Keeps the oldest LIVE candidate per surface: an existing entry that
    /// events have already defused (something was consumed after it was sent,
    /// so it can never satisfy the stall gate) is replaced, otherwise the
    /// older entry's earlier deadline is preserved across input bursts.
    func recordTerminalInputAwaitingEcho(surfaceID: String, sequence: UInt64) {
        let now = runtime?.now() ?? Date()
        if let existing = pendingTerminalInputEchoBySurfaceID[surfaceID],
           lastConsumedTerminalEventAt.map({ $0 < existing.sentAt }) ?? true {
            return
        }
        pendingTerminalInputEchoBySurfaceID[surfaceID] = PendingTerminalInputEcho(
            sequence: sequence,
            sentAt: now
        )
    }

    /// Clears every pending echo the delivered cumulative watermark covers.
    func resolveTerminalInputEcho(surfaceID: String, acknowledgedSequence: UInt64) {
        guard let pending = pendingTerminalInputEchoBySurfaceID[surfaceID],
              pending.sequence <= acknowledgedSequence else { return }
        pendingTerminalInputEchoBySurfaceID.removeValue(forKey: surfaceID)
    }

    /// A failed send never reached the host; it is not echo evidence.
    func failTerminalInputEcho(surfaceID: String, sequence: UInt64) {
        guard pendingTerminalInputEchoBySurfaceID[surfaceID]?.sequence == sequence else { return }
        pendingTerminalInputEchoBySurfaceID.removeValue(forKey: surfaceID)
    }

    /// Stamped only by envelopes the listener loop actually consumes.
    func recordConsumedTerminalEventForInputEcho() {
        lastConsumedTerminalEventAt = runtime?.now() ?? Date()
    }

    func clearTerminalInputEchoTracking(surfaceID: String? = nil) {
        if let surfaceID {
            pendingTerminalInputEchoBySurfaceID.removeValue(forKey: surfaceID)
        } else {
            pendingTerminalInputEchoBySurfaceID.removeAll()
            lastConsumedTerminalEventAt = nil
        }
    }

    /// The stall verdict: a marked input past the threshold with zero
    /// consumed events since its dispatch. Any consumed envelope after the
    /// dispatch (any surface, any topic) defuses the evidence — a flowing
    /// stream is alive even when the program never echoes the marker.
    func hasStalledTerminalInputEcho(now: Date) -> Bool {
        pendingTerminalInputEchoBySurfaceID.values.contains { pending in
            now.timeIntervalSince(pending.sentAt) >= Self.terminalInputEchoStallThreshold
                && lastConsumedTerminalEventAt.map { $0 < pending.sentAt } ?? true
        }
    }

    /// Whether a healthy-probe output-path repair may fire now (rate limit for
    /// the never-echoing-program false positive).
    func canRepairForTerminalInputEchoStall(now: Date) -> Bool {
        lastTerminalInputEchoRepairAt.map {
            now.timeIntervalSince($0) >= Self.terminalInputEchoRepairMinimumInterval
        } ?? true
    }

    /// Consumes the pending evidence before an output-path repair so the next
    /// escalation needs fresh typed-input proof.
    func noteTerminalInputEchoRepair(now: Date) {
        lastTerminalInputEchoRepairAt = now
        pendingTerminalInputEchoBySurfaceID.removeAll()
    }
}
