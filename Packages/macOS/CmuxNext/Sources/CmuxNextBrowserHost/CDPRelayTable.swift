import CmuxNextCompat

/// One relayed CEF tab's CDP id map (``CDPRawIDMap``), shared by the main actor and the provider
/// connection's write queue (plans/cmux-next/main-thread-budget.md, automation never blocks the
/// main thread).
///
/// The main actor maps each host command into the raw range before it hands it to Chromium (CEF's
/// UI thread is the main thread). A reply or event from Chromium is mapped back on the write
/// queue, where the frame is also encoded: the main thread only queues the message, whatever its
/// size (a screenshot or a DOM reply is megabytes). The lock guards the map's few dictionary
/// entries; each call holds it for one lookup or insert, and the byte scans of large messages run
/// outside it.
nonisolated final class CDPRelayTable: Sendable {
    private let map: Mutex<CDPRawIDMap>

    init(firstRawID: Int? = nil) {
        map = Mutex(CDPRawIDMap(firstRawID: firstRawID))
    }

    /// The raw id the next command gets.
    var nextRawID: Int { map.withLock { $0.nextRawID } }

    /// ``CDPRawIDMap/outbound(_:)`` under the lock.
    func outbound(_ message: String) -> (message: String, rawID: Int, hostID: Int)? {
        map.withLock { $0.outbound(message) }
    }

    /// ``CDPRawIDMap/forget(rawID:)`` under the lock.
    func forget(rawID: Int) {
        map.withLock { $0.forget(rawID: rawID) }
    }

    /// ``CDPRawIDMap/inbound(_:)``: the scan for the message's id and the rewrite run outside the
    /// lock; only the pending lookup holds it.
    func inbound(_ message: String) -> String? {
        guard let id = CDPRawIDMap.topLevelID(in: message) else { return message }
        guard let hostID = map.withLock({ $0.claim(rawID: id) }) else { return nil }
        return CDPRawIDMap.replacingID(in: message, with: hostID)
    }

    /// ``CDPRawIDMap/drainPending()`` under the lock.
    func drainPending() -> [(hostID: Int, sessionID: String?)] {
        map.withLock { $0.drainPending() }
    }
}
