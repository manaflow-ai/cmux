import CmuxMobileDiff
import Foundation
import Observation

/// The line diffs of the agent's edits, computed once per edit off the main thread.
///
/// A diff (`DiffFile(path:edits:)`, Myers over every line) of a large rewrite takes
/// hundreds of milliseconds; the transcript used to run one per row body, on every
/// streamed token. Rows ask here instead: a ready diff comes back at once; a missing one
/// starts on a background task, the row draws without it, and `version` changes when it
/// lands so the rows that waited are built again.
@MainActor
@Observable
public final class ChatDiffCache {
    /// Bumps each time a diff lands.
    public private(set) var version = 0
    @ObservationIgnored private var callFiles: [String: Entry<[EditPreview]>] = [:]
    @ObservationIgnored private var turnSets: [String: Entry<DiffChangeSet?>] = [:]
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// Diffs computed (tests: each edit once, however often its rows are built).
    @ObservationIgnored private(set) var computations = 0
    /// Runs a diff; tests replace it to count or to block.
    @ObservationIgnored var compute: @Sendable ([EditInput]) -> [DiffFile] = ChatDiffCache.diffFiles

    public init() {}

    /// One file of an edit's snippet with its unified preview lines (12, and 400 after
    /// "Show more"), computed with the diff: `unifiedPreview` builds every hunk's header and
    /// took seconds in a row body for a 2400-line rewrite.
    struct EditPreview: Equatable, Sendable {
        var file: DiffFile
        var short: (lines: [DiffLine], remaining: Int)
        var long: (lines: [DiffLine], remaining: Int)

        init(_ file: DiffFile) {
            self.file = file
            let lines = Self.changedLines(file.lines, context: 1)
            short = (Array(lines.prefix(12)), max(0, lines.count - 12))
            long = (Array(lines.prefix(400)), max(0, lines.count - 400))
        }

        /// `DiffFile.unifiedPreview`'s lines (each change with `context` lines around it,
        /// overlapping runs merged) in one forward pass. `unifiedPreview` builds every hunk's
        /// header with a backward search per hunk: O(hunks x lines), seconds on a 2400-line
        /// rewrite, and a snippet never shows the headers.
        static func changedLines(_ lines: [DiffLine], context: Int) -> [DiffLine] {
            var out: [DiffLine] = []
            var end = -1
            for index in lines.indices where lines[index].kind != .context || lines[index].isGap {
                let low = max(0, index - context, end + 1)
                let high = min(lines.count - 1, index + context)
                if low <= high { out += lines[low...high] }
                end = max(end, high)
            }
            return out
        }

        static func == (a: Self, b: Self) -> Bool {
            a.file == b.file && a.short.lines == b.short.lines && a.short.remaining == b.short.remaining
                && a.long.lines == b.long.lines && a.long.remaining == b.long.remaining
        }
    }

    public struct EditInput: Equatable, Sendable {
        var path: String
        var oldText: String?
        var newText: String
    }

    private struct Entry<Value> {
        var inputs: [EditInput]
        /// nil while the diff is computing.
        var value: Value?
    }

    // MARK: Lookups

    /// One file per diff of `call` (its snippet), or nil while it computes.
    func files(for call: ACPToolCall) -> [EditPreview]? {
        _ = version
        let inputs = call.diffs.map { EditInput(path: $0.path, oldText: $0.oldText, newText: $0.newText) }
        let key = "c-\(call.id)"
        if let entry = callFiles[key], entry.inputs == inputs {
            return entry.value
        }
        callFiles[key] = Entry(inputs: inputs, value: nil)
        running[key]?.cancel()
        computations += 1
        let compute = compute
        let work = Task.detached(priority: .userInitiated) {
            inputs.flatMap { compute([$0]) }.map(EditPreview.init)
        }
        running[key] = Task { [weak self] in
            let previews = await work.value
            guard let self, !Task.isCancelled else { return }
            self.running[key] = nil
            guard self.callFiles[key]?.inputs == inputs else { return }
            self.callFiles[key]?.value = previews
            self.version &+= 1
        }
        return nil
    }

    /// The turn's changes (its edited-files card), `.some(nil)` when it has none, or nil
    /// while they compute.
    func changeSet(for turn: AgentTurn) -> DiffChangeSet?? {
        _ = version
        let inputs = Self.inputs(turn)
        guard !inputs.isEmpty else { return .some(nil) }
        let key = "t-\(turn.id)"
        if let entry = turnSets[key], entry.inputs == inputs {
            return entry.value
        }
        turnSets[key] = Entry(inputs: inputs, value: nil)
        let turnID = turn.id
        start(key, inputs: inputs) { cache, files in
            guard cache.turnSets[key]?.inputs == inputs else { return }
            cache.turnSets[key]?.value = .some(Self.changeSet(turnID: turnID, files: files))
        }
        return nil
    }

    /// The turn's changes for a tap on a snippet or a menu: the cached diff, else the one
    /// computing (awaited), else computed off the main thread now. The main thread never runs
    /// the diff (hundreds of milliseconds for a large rewrite).
    func changeSetReady(for turn: AgentTurn) async -> DiffChangeSet? {
        if case .some(let ready) = changeSet(for: turn) { return ready }
        let key = "t-\(turn.id)"
        let inputs = Self.inputs(turn)
        if let task = running[key] { await task.value }
        if let entry = turnSets[key], entry.inputs == inputs, case .some(let ready) = entry.value { return ready }
        computations += 1
        let compute = compute
        let files = await Task.detached(priority: .userInitiated) { compute(inputs) }.value
        return Self.changeSet(turnID: turn.id, files: files)
    }

    /// Waits for the diffs that are computing (tests).
    func settle() async {
        while let task = running.values.first {
            await task.value
        }
    }

    // MARK: Work

    private func start(_ key: String, inputs: [EditInput],
                       land: @escaping @MainActor (ChatDiffCache, [DiffFile]) -> Void) {
        running[key]?.cancel()
        computations += 1
        let compute = compute
        let work = Task.detached(priority: .userInitiated) { compute(inputs) }
        running[key] = Task { [weak self] in
            let files = await work.value
            guard let self, !Task.isCancelled else { return }
            self.running[key] = nil
            land(self, files)
            self.version &+= 1
        }
    }

    private static func inputs(_ turn: AgentTurn) -> [EditInput] {
        turn.edits.map { EditInput(path: $0.path, oldText: $0.oldText, newText: $0.newText) }
    }

    private static func changeSet(turnID: String, files: [DiffFile]) -> DiffChangeSet? {
        files.isEmpty ? nil : DiffChangeSet(id: "turn-\(turnID)", title: "Changes", subtitle: "This turn", files: files)
    }

    /// `AgentTurn.diffFiles`: one file per path in first-edit order, from all its edits.
    nonisolated static func diffFiles(_ inputs: [EditInput]) -> [DiffFile] {
        AgentTurn.diffFiles(inputs.map { (path: $0.path, oldText: $0.oldText, newText: $0.newText) })
    }
}
