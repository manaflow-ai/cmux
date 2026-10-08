import Foundation

/// What the sidebar shows, read from this Chief's files.
struct HomeChiefSnapshot: Sendable {
    var harness: String?
    var model: String?
    var effort: String?
    var avatar: String?
    /// This Chief's acpmux has a CodeRouter Claude route (`claude-cr`).
    var routeConfigured = false
    /// The trace's last `turn.end`s, newest first.
    var turns: [HomeEngineTurn]
}

/// This Chief's files under its mux home: `optchat/engine.json` (the engine
/// optchat-chief reads at each turn start), `optchat/profile.json` (the
/// avatar) and `optchat/traces/` (read only). Blocking file I/O, so it runs
/// off the main actor.
nonisolated struct HomeChiefFiles: Sendable {
    let muxHome: URL
    var engineFile: URL { muxHome.appendingPathComponent("optchat/engine.json") }
    var profileFile: URL { muxHome.appendingPathComponent("optchat/profile.json") }
    var traceDirectory: URL { muxHome.appendingPathComponent("optchat/traces", isDirectory: true) }
    /// The Chief home's acpmux config (`ChiefHome.acpmuxHome`), read only.
    var acpmuxConfigFile: URL { muxHome.appendingPathComponent("acpmux/config.json") }

    private func object(_ file: URL) -> [String: Any] {
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func snapshot() -> HomeChiefSnapshot {
        let choice = object(engineFile)
        let avatar = (object(profileFile)["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HomeChiefSnapshot(harness: choice["harness"] as? String, model: choice["model"] as? String,
                                 effort: choice["effort"] as? String, avatar: avatar,
                                 routeConfigured: coderouterRouteConfigured(environment: ProcessInfo.processInfo.environment),
                                 turns: recentTurns(limit: 5))
    }

    /// Whether this Chief's acpmux has a CodeRouter Claude route configured:
    /// `ACPMUX_CODEROUTER_CLAUDE_ROUTE` in the environment the Chief's acpmux
    /// inherits, else `coderouterClaudeRoute` in its config.json (acpmux
    /// `coderouter_claude_route`). Blank values do not count.
    func coderouterRouteConfigured(environment: [String: String]) -> Bool {
        let configured = { (value: String?) in !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if let value = environment["ACPMUX_CODEROUTER_CLAUDE_ROUTE"] { return configured(value) }
        return configured(object(acpmuxConfigFile)["coderouterClaudeRoute"] as? String)
    }

    /// The avatar alone (the header reads it when Home opens).
    func avatar() -> String? { snapshot().avatar }

    /// Sets (or with nil clears) one engine field; the compactor fields stay.
    func setEngine(_ key: String, _ value: String?) {
        var choice = object(engineFile)
        if let value { choice[key] = value } else { choice.removeValue(forKey: key) }
        write(choice, to: engineFile)
    }

    func writeAvatar(_ text: String) {
        var profile = object(profileFile)
        if text.isEmpty { profile.removeValue(forKey: "avatar") } else { profile["avatar"] = text }
        write(profile, to: profileFile)
    }

    /// 0600, through a temporary file and a replace, as optchat-chief writes.
    private func write(_ object: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(file.lastPathComponent + ".app.tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data + Data("\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try? FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    /// The trace's last `turn.end`s, newest first (today's file, then yesterday's).
    func recentTurns(limit: Int) -> [HomeEngineTurn] {
        var found: [HomeEngineTurn] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for offset in [0, -1] {
            let day = formatter.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
            let file = traceDirectory.appendingPathComponent("\(day).jsonl")
            // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"turn.end\"") {
                if let turn = HomeEngineTurn(line: String(line)) { found.append(turn) }
                if found.count >= limit { return found }
            }
        }
        return found
    }
}
