public import Foundation

/// What each agent chat's page held that acpmux does not (``AgentPaneWakeState``: the composer's
/// attachments, shell mode with its unrun command, where the transcript rested), by tab, in a JSON
/// file in the tag's state directory. The quit's window step saves it (`QuitCoordinator`), so every
/// relaunch that goes through the quit (Restart to Update, SIGTERM's Quit and keep sessions,
/// Cmd-Q) keeps it; the next launch hands it to each tab's first page with its handshake, as a
/// woken hibernated page gets it. The draft's text is acpmux's and a new chat's is
/// ``AgentUnsentDrafts``'.
public final class AgentPaneRelaunchWake {
    public static let fileName = "agent-pane-wake-states.json"
    /// Attachments carry their contents: a tab holding more is not kept, and the file stops growing
    /// past ``maximumBytes`` (the launch reads it on the main actor; a larger file is not read).
    nonisolated static let maximumTabBytes = 4 * 1024 * 1024
    nonisolated static let maximumBytes = 8 * 1024 * 1024

    let file: URL?
    /// Asks a live page what it holds, within the limit (``AgentPaneView/wakeState(limit:)``).
    public var read: @MainActor (AgentPaneView, Duration) async -> AgentPaneWakeState? = { await $0.wakeState(limit: $1) }

    public init(file: URL?) {
        self.file = file
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// The last quit's states, by tab, once: the file goes, so a crash later in this run never
    /// brings back chips already sent.
    public func take() -> [String: AgentPaneWakeState] {
        guard let file else { return [:] }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              // concurrency-allow: one capped read of a small local state file when the tab store is made
              let data = try? Data(contentsOf: file),
              let states = try? JSONDecoder().decode([String: AgentPaneWakeState].self, from: data) else { return [:] }
        return states.filter { !$0.value.isEmpty }
    }

    /// What every chat holds for the next launch, by tab: `held` (released pages' states, by tab),
    /// then each page in `pages`. A page that has not taken its state yet (no `ready`, only a
    /// reconnect) keeps it unasked; every other page is asked at once, each within `limit`, and
    /// one that does not answer keeps the tab's held state or the one its `ready` took. Tabs
    /// `live` refuses (gone from every tree) keep nothing.
    public func collect(held: [String: AgentPaneWakeState], pages: [(key: String, view: AgentPaneView)],
                        live: (String) -> Bool, limit: Duration = .seconds(1)) async -> [String: AgentPaneWakeState] {
        var states = held
        let read = read
        // task-owner: every ask is awaited below, before the quit goes on.
        let asks = pages.map { page in
            (page, page.view.model.pendingWake == nil && page.view.model.hasHandshake ? Task { await read(page.view, limit) } : nil)
        }
        for (page, ask) in asks {
            let model = page.view.model
            let answer = await ask?.value
            states[page.key] = answer ?? model.pendingWake ?? states[page.key] ?? model.handedWake
        }
        return states.filter { key, state in !state.isEmpty && live(key) }
    }

    /// Replaces the saved states with `states` (by tab key); with none held the file goes.
    public func save(_ states: [String: AgentPaneWakeState]) async {
        guard let file else { return }
        let held = states.filter { !$0.value.isEmpty }
        await Task.detached { Self.write(held, to: file) }.value
    }

    private nonisolated static func write(_ states: [String: AgentPaneWakeState], to file: URL) {
        let encoder = JSONEncoder()
        var kept: [String: AgentPaneWakeState] = [:]
        var total = 0
        // Smallest first, so one tab's large attachments never cost every other tab its composer.
        let sized = states.compactMap { key, state in (try? encoder.encode(state)).map { (key, state, $0.count) } }
        for (key, state, size) in sized.sorted(by: { $0.2 < $1.2 }) where size <= maximumTabBytes && total + size <= maximumBytes {
            kept[key] = state
            total += size
        }
        guard !kept.isEmpty, let data = try? encoder.encode(kept) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
    }
}
