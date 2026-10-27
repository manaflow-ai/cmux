import Foundation

/// Sites (origins) an agent scripted and sites holding a filled Secure Store login, per browser
/// profile, kept across app restarts (cmux https://github.com/manaflow-ai/cmux/issues/25830). The
/// two exclude each other for good:
///
/// - An agent script (`eval`, `wait --function`) on an origin whose sign-in was filled is refused,
///   so no script of that site's origin (in any tab, popup or frame) can read the password back.
/// - `fill_login` on an origin an agent ever scripted is refused: that script could have left a
///   hook behind in another tab of the origin, an opener handle or a service worker.
///
/// An origin is `scheme://host[:port]` as `location.origin` gives it, keyed with the tab's
/// profile (each profile has its own storage and service workers). Check and mark happen in one
/// actor step, so a script and a fill racing on one origin cannot both pass. The file is read
/// once, on first use, and written on each change, all on this actor, never the main thread.
actor BrowserLoginGuards {
    private struct Saved: Codable {
        var scripted: [String]
        var filled: [String]
    }

    private let file: URL?
    private var scripted: Set<String> = []
    private var filled: Set<String> = []
    private var loaded = false

    /// - Parameter file: where the marks persist; nil keeps them in memory only.
    init(file: URL?) {
        self.file = file
    }

    /// An agent script is about to run on a page of `origins` (nil: the origin could not be
    /// read; empty: an opaque page, no site). False when one of them holds a filled login, or
    /// when the origin is unknown and this profile holds any; else each is marked scripted.
    func beginScript(profile: String?, origins: [String]?) -> Bool {
        load()
        guard let origins else {
            let prefix = Self.key(profile: profile, origin: "")
            return !filled.contains { $0.hasPrefix(prefix) }
        }
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        if keys.contains(where: filled.contains) { return false }
        insertScripted(keys)
        return true
    }

    /// Marks `origins` scripted after a script ran (it may have moved to another site).
    func markScripted(profile: String?, origins: [String]?) {
        load()
        insertScripted((origins ?? []).map { Self.key(profile: profile, origin: $0) })
    }

    /// A login is about to be filled into a page of `origins`. False when an agent scripted one
    /// of them; else each is marked filled.
    func beginFill(profile: String?, origins: [String]) -> Bool {
        load()
        let keys = origins.map { Self.key(profile: profile, origin: $0) }
        if keys.contains(where: scripted.contains) { return false }
        insertFilled(keys)
        return true
    }

    /// The fill set nothing on `origins` (no login field, or the page moved first).
    func forgetFill(profile: String?, origins: [String]) {
        load()
        let keys = Set(origins.map { Self.key(profile: profile, origin: $0) })
        guard !filled.isDisjoint(with: keys) else { return }
        filled.subtract(keys)
        save()
    }

    static func key(profile: String?, origin: String) -> String {
        "\(profile?.lowercased() ?? BrowserPageService.agentBrowserProfileID)|\(origin)"
    }

    private func insertScripted(_ keys: [String]) {
        let before = scripted.count
        scripted.formUnion(keys)
        if scripted.count != before { save() }
    }

    private func insertFilled(_ keys: [String]) {
        let before = filled.count
        filled.formUnion(keys)
        if filled.count != before { save() }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        scripted = Set(saved.scripted)
        filled = Set(saved.filled)
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Saved(scripted: scripted.sorted(), filled: filled.sorted())) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
