import CmuxNextBrowser
import CmuxNextSettings

/// The latest wakes of hibernated pages (`debug.surfaces` `wakes`, scripts/cmux-next/bench_hibernation.py):
/// from the `restore` effect to the page being back (`mounted_ms`) and to its load ending
/// (`loaded_ms`, nil while it loads or when it did not end within 15 s), whether a snapshot
/// covered the pane meanwhile, and whether the tab was shown when it came back (a neighbor or a
/// hover wakes it hidden).
nonisolated struct HibernationWakes {
    nonisolated struct Wake: Equatable {
        let tab: String
        let engine: BrowserEngineKind
        let snapshot: Bool
        var mountedMs: Int?
        var loadedMs: Int?
        var visible = false
    }

    /// Wakes kept, newest last.
    static let limit = 32
    private(set) var records: [Wake] = []
    private var started: [String: (at: ContinuousClock.Instant, engine: BrowserEngineKind, snapshot: Bool)] = [:]

    mutating func start(_ key: String, engine: BrowserEngineKind, snapshot: Bool, at now: ContinuousClock.Instant = .now) {
        started[key] = (now, engine, snapshot)
    }

    mutating func mounted(_ key: String, visible: Bool, at now: ContinuousClock.Instant = .now) {
        guard let start = started[key] else { return }
        records.append(Wake(tab: key, engine: start.engine, snapshot: start.snapshot,
                            mountedMs: Self.milliseconds(now - start.at), visible: visible))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }

    /// The woken page's load ended (`ended`), or did not in time.
    mutating func loaded(_ key: String, ended: Bool, at now: ContinuousClock.Instant = .now) {
        guard let start = started.removeValue(forKey: key), ended,
              let index = records.lastIndex(where: { $0.tab == key }), records[index].loadedMs == nil else { return }
        records[index].loadedMs = Self.milliseconds(now - start.at)
    }

    mutating func forget(_ key: String) {
        started[key] = nil
    }

    var json: JSONValue {
        .array(records.map { wake -> JSONValue in
            [
                "tab": .string(wake.tab), "engine": .string(wake.engine == .cef ? "chromium" : "webkit"),
                "snapshot": .bool(wake.snapshot), "visible": .bool(wake.visible),
                "mounted_ms": wake.mountedMs.map { JSONValue($0) } ?? .null, "loaded_ms": wake.loadedMs.map { JSONValue($0) } ?? .null,
            ]
        })
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
