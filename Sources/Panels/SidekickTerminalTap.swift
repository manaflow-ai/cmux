import Foundation

/// Cheap, lock-free entry point for any terminal-write hook to feed
/// raw output chunks to the sidekick URL detector.
///
/// Why a separate file: `TerminalSurface.forceRefresh()` /
/// `GhosttySurfaceScrollView` are flagged in CLAUDE.md as
/// typing-latency-sensitive paths. The actual instrumentation site
/// stays out of the hot path (ghostty wakeup callback in a future
/// upstream PR); this file is the *receiving* side, kept allocation-
/// free in the steady state so the hot-path callee just calls
/// `SidekickTerminalTap.feed(panelID:chunk:)`.
///
/// Pipeline per chunk:
///   1. Extract URLs (NSRegularExpression, single shared instance).
///   2. Dedupe against a tiny per-panel ring (last 32 URLs).
///   3. Post `.cmuxSidekickURLDetected` for fresh URLs.
///
/// The detector itself runs synchronously on the caller's thread;
/// notification posting hops to main. Keep this fast — every keystroke
/// in a terminal that prints back may flow through here.
public enum SidekickTerminalTap {
    private static let queue = DispatchQueue(
        label: "cmux.sidekick.terminalTap",
        qos: .utility,
        attributes: .concurrent)

    nonisolated(unsafe) private static var recent: [UUID: [String]] = [:]
    nonisolated(unsafe) private static var recentLock = os_unfair_lock_s()

    public static func feed(panelID: UUID, chunk: String) {
        let urls = SidekickURLDetector.extract(from: chunk)
        guard !urls.isEmpty else { return }
        let fresh = filterFresh(panelID: panelID, urls: urls)
        guard !fresh.isEmpty else { return }
        DispatchQueue.main.async {
            for url in fresh {
                NotificationCenter.default.post(
                    name: .cmuxSidekickURLDetected,
                    object: nil,
                    userInfo: ["panelID": panelID, "url": url])
            }
        }
    }

    private static func filterFresh(panelID: UUID, urls: [URL]) -> [URL] {
        os_unfair_lock_lock(&recentLock)
        defer { os_unfair_lock_unlock(&recentLock) }
        var ring = recent[panelID] ?? []
        var out: [URL] = []
        for url in urls {
            let key = url.absoluteString
            if !ring.contains(key) {
                ring.append(key)
                if ring.count > 32 { ring.removeFirst(ring.count - 32) }
                out.append(url)
            }
        }
        recent[panelID] = ring
        return out
    }

    /// Forget per-panel history (call when a terminal panel closes).
    public static func purge(panelID: UUID) {
        os_unfair_lock_lock(&recentLock)
        defer { os_unfair_lock_unlock(&recentLock) }
        recent.removeValue(forKey: panelID)
    }
}
