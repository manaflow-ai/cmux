public import Foundation

/// What each agent chat's page held that acpmux does not (``AgentPaneWakeState``: the composer's
/// attachments, shell mode with its unrun command, where the transcript rested), by tab, in a JSON
/// file in the tag's state directory. The quit's window step saves it (`QuitCoordinator`), so every
/// relaunch that goes through the quit (Restart to Update, SIGTERM's Quit and keep sessions,
/// Cmd-Q) keeps it; the next launch hands it to each tab's first page with its handshake, as a
/// woken hibernated page gets it. The draft's text is acpmux's and a new chat's is
/// ``AgentUnsentDrafts``'.
///
/// An attachment's contents (a pasted screenshot, a PDF, a recording) are copied into
/// ``attachmentsDirectoryName`` beside the JSON file as their own bytes, so the JSON stays small and
/// four Retina screenshots no longer push a tab past the JSON's cap (Leo 2026-10-20: the draft's
/// text came back, its screenshots did not). The launch reads only the JSON, removes it and takes
/// the attachments' folder for its own (``takenAttachmentsDirectoryName``), so a chip sent or taken
/// out later in that run is never saved again; each chat reads its chips' contents from there when
/// its page asks (``AgentPaneWakeState/readingBack(budget:)``, off the main thread), and a chat
/// whose page never asked has its files carried into the next quit's save (#17587: the launch read
/// up to 128 MB back into memory before the first window frame).
public final class AgentPaneRelaunchWake {
    public nonisolated static let fileName = "agent-pane-wake-states.json"
    public nonisolated static let attachmentsDirectoryName = "agent-pane-wake-attachments"
    /// The launch's own copy of ``attachmentsDirectoryName``, beside it: the files this run's chats
    /// read their chips from. The next launch removes it before it takes the folder again.
    public nonisolated static let takenAttachmentsDirectoryName = "agent-pane-wake-attachments.taken"
    /// The attachments' files a save keeps, all tabs together (``maximumAttachmentBytes``'s default); also
    /// the most one chat reads back (``AgentPaneWakeState/readingBack(budget:)``).
    public nonisolated static let defaultMaximumAttachmentBytes = 128 * 1024 * 1024
    /// The JSON (shell commands, text files' text, file names): a tab holding more is not kept, and
    /// the file stops growing past ``maximumBytes`` (the launch reads it on the main actor; a larger
    /// file is not read).
    nonisolated static let maximumTabBytes = 4 * 1024 * 1024
    nonisolated static let maximumBytes = 8 * 1024 * 1024
    let file: URL?
    /// The attachments' files a save keeps, all tabs together: a composer full of images (10 of at
    /// most 5 MB, `attachments.ts`) fits twice over.
    public var maximumAttachmentBytes = AgentPaneRelaunchWake.defaultMaximumAttachmentBytes
    /// Asks a live page what it holds, within the limit (``AgentPaneView/wakeState(limit:)``).
    public var read: @MainActor (AgentPaneView, Duration) async -> AgentPaneWakeState? = { await $0.wakeState(limit: $1) }

    public init(file: URL?) {
        self.file = file
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public nonisolated static func file(in directory: URL?) -> URL? {
        directory?.appending(path: fileName)
    }

    /// Where the attachments' files go: beside the JSON file.
    var attachmentsDirectory: URL? { Self.attachmentsDirectory(beside: file) }

    private nonisolated static func attachmentsDirectory(beside file: URL?, named name: String = attachmentsDirectoryName) -> URL? {
        file?.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
    }

    /// One tab's state as saved: its attachments' contents moved out to files.
    nonisolated struct Saved: Codable {
        var state: AgentPaneWakeState
        /// The file in the attachments directory holding each attachment's bytes, by attachment id.
        var files: [String: String]?
    }

    /// The last quit's states, by tab, once (``takeSaved(from:)`` on the calling thread; the launch
    /// takes them off the main thread through the app's `LaunchFiles`, #17587).
    public func take() -> [String: AgentPaneWakeState] {
        Self.takeSaved(from: file)
    }

    /// The states saved in `file`, by tab, once: the file goes and the attachments' folder becomes
    /// the launch's own (``takenAttachmentsDirectoryName``, the last launch's removed first), so a
    /// crash later in this run never brings back chips already sent. No chip's contents are read:
    /// a state whose chips have files keeps where they are (``AgentPaneWakeState/kept``), and its
    /// chat reads them when its page asks. Runs on any thread.
    public nonisolated static func takeSaved(from file: URL?) -> [String: AgentPaneWakeState] {
        guard let file else { return [:] }
        let manager = FileManager.default
        let folder = attachmentsDirectory(beside: file)
        let taken = attachmentsDirectory(beside: file, named: takenAttachmentsDirectoryName)
        if let taken {
            try? manager.removeItem(at: taken)
            if let folder { try? manager.moveItem(at: folder, to: taken) }
        }
        defer {
            try? manager.removeItem(at: file)
            // A folder that could not be taken goes: its chips are not handed back.
            if let folder { try? manager.removeItem(at: folder) }
        }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              // concurrency-allow: one capped read of a local state file, off the main thread at launch
              let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        let saved = (try? decoder.decode([String: Saved].self, from: data))
            // A file the last build wrote, contents inline.
            ?? (try? decoder.decode([String: AgentPaneWakeState].self, from: data))?.mapValues { Saved(state: $0) }
            ?? [:]
        let kept = taken.flatMap { manager.fileExists(atPath: $0.path) ? $0 : nil }
        return saved.compactMapValues { saved in
            var state = saved.state
            if let files = saved.files, !files.isEmpty {
                guard let kept else {
                    // No taken folder: the chips with files have no contents to come back with.
                    state.attachments = state.attachments?.filter { files[$0.id] == nil }
                    return state.isEmpty ? nil : state
                }
                state.kept = AgentPaneKeptChips(folder: kept, files: files)
            }
            return state.isEmpty ? nil : state
        }
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

    /// Replaces the saved states with `states` (by tab key); with none held the file and the
    /// attachments' files go.
    public func save(_ states: [String: AgentPaneWakeState]) async {
        guard let file, let folder = attachmentsDirectory else { return }
        let held = states.filter { !$0.value.isEmpty }
        let limit = maximumAttachmentBytes
        await Task.detached { Self.write(held, to: file, attachments: folder, limit: limit) }.value
    }

    private nonisolated static func write(_ states: [String: AgentPaneWakeState], to file: URL, attachments folder: URL, limit: Int) {
        let manager = FileManager.default
        // Only this save's files stay: the last save's are gone even when a tab drops out below.
        try? manager.removeItem(at: folder)
        let encoder = JSONEncoder()
        var kept: [String: Saved] = [:]
        var total = 0
        var attachmentTotal = 0
        // Smallest first, so one tab's large attachments never cost every other tab its composer.
        let sized = states.map { key, state in
            let inline = (state.attachments ?? []).reduce(0) { $0 + ($1.data?.utf8.count ?? 0) }
            let kept = state.kept.map { kept in kept.files.values.reduce(0) { $0 + (AgentPaneAttachmentFiles.size(of: $1, in: kept.folder) ?? 0) } } ?? 0
            return (key, state, inline + kept)
        }
        for (key, state, _) in sized.sorted(by: { $0.2 < $1.2 }) {
            // A chat whose page never asked for its chips this run still has them in the launch's folder.
            let carried = state.kept.map { AgentPaneAttachmentFiles.carry($0.files, from: $0.folder, into: folder) } ?? [:]
            guard let moved = AgentPaneAttachmentFiles.moveOut(state.attachments ?? [], to: folder, within: limit - attachmentTotal,
                                                              kept: carried) else { continue }
            var held = state
            held.kept = nil
            if state.attachments != nil { held.attachments = moved.attachments }
            let saved = Saved(state: held, files: moved.files.isEmpty ? nil : moved.files)
            guard let size = (try? encoder.encode(saved))?.count, size <= maximumTabBytes, total + size <= maximumBytes else { continue }
            kept[key] = saved
            total += size
            attachmentTotal += moved.bytes
        }
        guard !kept.isEmpty, let data = try? encoder.encode(kept) else {
            try? manager.removeItem(at: file)
            try? manager.removeItem(at: folder)
            return
        }
        try? data.write(to: file, options: .atomic)
        let referenced = Set(kept.values.flatMap { $0.files?.values.map { $0 } ?? [] })
        if referenced.isEmpty { try? manager.removeItem(at: folder) }
        // A tab that did not fit wrote files nothing names: they go.
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !referenced.contains(name) {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }
}
