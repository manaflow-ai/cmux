internal import CCmuxLayoutReducerFFI
public import Foundation

/// The history, search, file explorer and window hint rules (cmux-tui crate `cmux-app-history`),
/// asked over the app FFI's JSON channel (`app_history_*`). The app sends the facts and acts on
/// the answer; each call's fallback is what the app does when Rust does not answer.
public nonisolated enum AppHistoryRules {
    // MARK: Search All Windows

    /// Non-empty trimmed lines, oldest first.
    public static func searchLines(_ lines: [String]) -> [String] {
        ask("app_history_search_lines", ["lines": lines], as: [String: [String]].self)?["lines"] ?? []
    }

    /// The query's words, lowercased.
    public static func searchWords(_ query: String) -> [String] {
        ask("app_history_search_words", ["query": query], as: [String: [String]].self)?["words"] ?? []
    }

    /// The order to read sources in: those with text to read (`readable`), this Mac's (`local`) first.
    public static func searchReadOrder(_ sources: [(readable: Bool, local: Bool)]) -> [Int] {
        nonisolated struct Source: Encodable { let readable: Bool, local: Bool }
        let facts = sources.map { Source(readable: $0.readable, local: $0.local) }
        let order = ask("app_history_search_read_order", ["sources": facts], as: [String: [Int]].self)?["order"] ?? []
        return order.filter(sources.indices.contains)
    }

    /// `line` cut to about 48 characters ahead of the first word and 110 from it (an ellipsis
    /// where it was cut), and the word Find highlights: the first query word in it, as typed there.
    public static func searchRow(_ line: String, words: [String]) -> (snippet: String, needle: String) {
        nonisolated struct Request: Encodable { let words: [String], rows: [[String: String]] }
        nonisolated struct Row: Decodable { let snippet: String, needle: String }
        let row = ask("app_history_search_rows", Request(words: words, rows: [["line": line]]), as: [String: [Row]].self)?["rows"]?.first
        return (row?.snippet ?? line, row?.needle ?? "")
    }

    // MARK: Closed-tab retention

    /// One machine's facts at a retention check.
    public nonisolated struct ClosedCheck: Encodable, Sendable {
        let overLimit: Bool, maxAgeDays: UInt64, oldestMs: UInt64?, nowMs: UInt64, count: Int, closedLimit: Int
        let sinceLastPruneMs: UInt64?

        public init(overLimit: Bool, maxAgeDays: Int, oldestMs: UInt64?, nowMs: UInt64, count: Int, closedLimit: Int,
                    sinceLastPrune: Duration?) {
            (self.overLimit, self.maxAgeDays, self.oldestMs, self.nowMs) = (overLimit, UInt64(max(0, maxAgeDays)), oldestMs, nowMs)
            (self.count, self.closedLimit) = (count, closedLimit)
            sinceLastPruneMs = sinceLastPrune.map { UInt64(max(0, $0.components.seconds)) * 1000
                + UInt64(max(0, $0.components.attoseconds / 1_000_000_000_000_000)) }
        }
    }

    /// Send the delete now, when to check again, or cancel the deadline; `retry` is the wait after a failed delete.
    public nonisolated struct ClosedDecision: Sendable {
        public let prune: Bool, recheckAfter: Duration?, cancelDeadline: Bool, retry: Duration
    }

    public static func closedCheck(_ check: ClosedCheck) -> ClosedDecision? {
        nonisolated struct Answer: Decodable { let prune: Bool, recheckAfterMs: UInt64?, cancelDeadline: Bool, retryMs: UInt64 }
        guard let answer = ask("app_history_closed_check", check, as: Answer.self) else { return nil }
        return ClosedDecision(prune: answer.prune, recheckAfter: answer.recheckAfterMs.map { .milliseconds(Int64(clamping: $0)) },
                              cancelDeadline: answer.cancelDeadline, retry: .milliseconds(Int64(clamping: answer.retryMs)))
    }

    // MARK: Command history

    /// What a daemon was last sent: its boot generation, the switch and the retention.
    public nonisolated struct CommandSent: Codable, Equatable, Sendable {
        public let generation: String, enabled: Bool, retentionDays: Int
    }

    /// Ask to delete what was recorded, the machines to send `set-terminal-command-history`, and the new memory.
    public nonisolated struct CommandPlan: Decodable, Sendable {
        public let offerDeletion: Bool, send: [String], sent: [String: CommandSent], lastEnabled: Bool
    }

    /// One sync of the settings to the connected `machines` (by boot generation); `daemons`: machines with a daemon to send to.
    public static func commandSync(enabled: Bool, retentionDays: Int, machines: [String: String], sent: [String: CommandSent],
                                   lastEnabled: Bool?, daemons: [String]) -> CommandPlan? {
        nonisolated struct Request: Encodable {
            let enabled: Bool, retentionDays: Int, machines: [String: String], sent: [String: CommandSent]
            let lastEnabled: Bool?, daemons: [String]
        }
        let request = Request(enabled: enabled, retentionDays: retentionDays, machines: machines, sent: sent,
                              lastEnabled: lastEnabled, daemons: daemons)
        return ask("app_history_command_sync", request, as: CommandPlan.self)
    }

    // MARK: Find in files

    /// The trimmed query to run; nil when it is blank or there is no root.
    public static func findQuery(_ text: String, hasRoot: Bool) -> String? {
        nonisolated struct Request: Encodable { let text: String, hasRoot: Bool }
        return ask("app_history_find_query", Request(text: text, hasRoot: hasRoot), as: [String: String?].self)?["query"] ?? nil
    }

    /// The find section's state after a search ended.
    public nonisolated enum FindState: Equatable, Sendable { case done(limited: Bool), ripgrepMissing, ripgrepExited(Int32) }

    /// - Parameter outcome: nil when ripgrep is missing; else its exit status or whether the matches were limited.
    public static func findState(_ outcome: Result<Bool, FindFailure>?) -> FindState {
        nonisolated struct Outcome: Encodable { let kind: String, status: Int32?, limited: Bool? }
        nonisolated struct Answer: Decodable { let state: String, limited: Bool?, status: Int32? }
        let fact = switch outcome {
        case nil: Outcome(kind: "missing", status: nil, limited: nil)
        case .failure(let failure)?: Outcome(kind: "failed", status: failure.status, limited: nil)
        case .success(let limited)?: Outcome(kind: "matches", status: nil, limited: limited)
        }
        let answer = ask("app_history_find_state", ["outcome": fact], as: Answer.self)
        return switch answer?.state {
        case "done": .done(limited: answer?.limited ?? false)
        case "ripgrepExited": .ripgrepExited(answer?.status ?? 0)
        default: .ripgrepMissing
        }
    }

    /// ripgrep's exit status when it failed before finding anything.
    public nonisolated struct FindFailure: Error, Sendable {
        let status: Int32
        public init(status: Int32) { self.status = status }
    }

    // MARK: File explorer

    /// Whether a folder may be read: it is not protected, or it is in a folder the person asked to see.
    public static func fileMayRead(protected: Bool, folder: String, asked: [String]) -> Bool {
        nonisolated struct Request: Encodable { let protected: Bool, folder: String, asked: [String] }
        let request = Request(protected: protected, folder: folder, asked: asked)
        return ask("app_history_file_may_read", request, as: [String: Bool].self)?["mayRead"] ?? !protected
    }

    /// `path` under `root` ("Sources/App.swift"); the full path outside it or without a root.
    public static func fileRelative(_ path: String, root: String?) -> String {
        nonisolated struct Request: Encodable { let root: String?, path: String }
        return ask("app_history_file_relative", Request(root: root, path: path), as: [String: String].self)?["path"] ?? path
    }

    /// Git's states (by absolute path) under `top` from `git status`'s entries (path under top, state),
    /// and the folders with a changed item inside.
    public static func fileGit(top: String, entries: [String: String]) -> (states: [String: String], folders: Set<String>) {
        nonisolated struct Entry: Encodable { let path: String, state: String }
        nonisolated struct Request: Encodable { let top: String, entries: [Entry] }
        nonisolated struct Tree: Decodable { let states: [String: String], folders: Set<String> }
        let request = Request(top: top, entries: entries.map { Entry(path: $0.key, state: $0.value) })
        let tree = ask("app_history_file_git", request, as: Tree.self)
        return (tree?.states ?? [:], tree?.folders ?? [])
    }

    /// One listed entry, in the app's display order.
    public nonisolated struct FileEntry: Encodable, Sendable {
        let path: String, name: String, isFolder: Bool
        public init(path: String, name: String, isFolder: Bool) { (self.path, self.name, self.isFolder) = (path, name, isFolder) }
    }

    /// One visible row; `git` is the state's raw value.
    public nonisolated struct FileRow: Decodable, Sendable {
        public let path: String, name: String, depth: Int, isFolder: Bool, isExpanded: Bool, git: String?
    }

    /// The visible rows: each expanded folder's entries under it, one level deeper, with git states.
    public static func fileRows(root: String, resolvedRoot: String, children: [String: [FileEntry]], expanded: [String],
                                states: [String: String], folders: Set<String>) -> [FileRow] {
        nonisolated struct Tree: Encodable {
            let root: String, resolvedRoot: String, children: [String: [FileEntry]], expanded: [String]
            let states: [String: String], folders: Set<String>
        }
        let tree = Tree(root: root, resolvedRoot: resolvedRoot, children: children, expanded: expanded, states: states, folders: folders)
        return ask("app_history_file_rows", tree, as: [String: [FileRow]].self)?["rows"] ?? []
    }

    // MARK: Window hints

    /// The frames that get a hint, by index in walk order, clipped to `bounds`: at least 4 by 4,
    /// one per rounded rect, at most `limit`.
    public static func hintRects(_ frames: [CGRect], bounds: CGRect, limit: Int) -> [(index: Int, rect: CGRect)] {
        nonisolated struct Request: Encodable { let frames: [[Double]], bounds: [Double], limit: Int }
        nonisolated struct Kept: Decodable { let index: Int, rect: [Double] }
        let request = Request(frames: frames.map(box), bounds: box(bounds), limit: limit)
        let kept = ask("app_history_hint_rects", request, as: [String: [Kept]].self)?["kept"] ?? []
        return kept.compactMap { kept in rect(kept.rect).map { (kept.index, $0) } }
    }

    /// One page link's corners in its web view's coordinates, its center (CSS pixels) and its text.
    public nonisolated struct PageLink: Decodable, Sendable {
        let near: [Double], far: [Double]
        public let x: Double, y: Double, text: String
        public var nearPoint: CGPoint { point(near) }
        public var farPoint: CGPoint { point(far) }
    }

    /// The page script's answer (JSON) as view-local corners; the far corner mirrors the near one through the center.
    public static func hintPage(_ answer: String, zoom: Double, flipped: Bool, height: Double) -> [PageLink] {
        nonisolated struct View: Encodable { let zoom: Double, flipped: Bool, height: Double }
        nonisolated struct Request: Encodable { let answer: String, view: View }
        let request = Request(answer: answer, view: View(zoom: zoom, flipped: flipped, height: height))
        return ask("app_history_hint_page", request, as: [String: [PageLink]].self)?["links"] ?? []
    }

    /// A page link's target from its window corners: the box between them, clipped, at least 4 by 4.
    public static func hintPageRect(near: CGPoint, far: CGPoint, clip: CGRect) -> CGRect? {
        nonisolated struct Request: Encodable { let near: [Double], far: [Double], clip: [Double] }
        let request = Request(near: [near.x, near.y], far: [far.x, far.y], clip: box(clip))
        return ask("app_history_hint_page_rect", request, as: [String: [Double]?].self)?["rect"]?.flatMap(rect)
    }

    // MARK: The channel

    /// JSON has no infinity: a rect that is not finite (a null rect) is sent empty, which nothing keeps.
    private static func box(_ rect: CGRect) -> [Double] {
        let sides = [rect.origin.x, rect.origin.y, rect.width, rect.height].map(Double.init)
        return sides.allSatisfy(\.isFinite) ? sides : [0, 0, 0, 0]
    }

    private static func rect(_ sides: [Double]) -> CGRect? {
        sides.count == 4 ? CGRect(x: sides[0], y: sides[1], width: sides[2], height: sides[3]) : nil
    }

    private static func point(_ sides: [Double]) -> CGPoint {
        sides.count == 2 ? CGPoint(x: sides[0], y: sides[1]) : .zero
    }

    private static func ask<Answer: Decodable>(_ operation: String, _ request: some Encodable, as _: Answer.Type) -> Answer? {
        guard let body = try? JSONEncoder().encode(request), let data = call(operation, body) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    private static func call(_ operation: String, _ request: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}
