public import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Reverts in a repository (D3, ``AgentPaneGitDiscard``): whole files, one hunk, and Undo of a hunk.
public protocol DiffGitReverting: AnyObject {
    /// `git.discard` or `git.discardHunk` in `repository`.
    func discard(_ request: AgentPaneGitDiscard, in repository: String) async -> AgentPaneGitDiscard.Outcome
    /// Puts a reverted hunk back in `repository`'s work tree; nil on success, else why not.
    func reapply(_ undo: AgentPaneGitDiscard.Undo, in repository: String) async -> String?
}

/// What the Revert sheet asks before files lose their changes: built by the host from the request
/// itself, so the sheet names what will really go.
public nonisolated struct DiffRevertPrompt: Equatable, Sendable {
    /// The most file names the sheet lists before "and N more".
    static let listed = 6

    public let title: String
    public let lines: [String]
    /// The destructive button's title.
    public let confirm: String

    /// `sources` are the paths that are a rename's previous path: a renamed file counts once, but
    /// both of its paths are listed, since both change.
    init(_ request: AgentPaneGitDiscard, sources: Set<String> = []) {
        let files = max(1, request.paths.count - request.paths.filter(sources.contains).count)
        title = files == 1
            ? String(format: DiffPageStrings.revertOneTitle, request.paths[0])
            : String(format: DiffPageStrings.revertManyTitle, files)
        var lines = [request.scope == .uncommitted ? DiffPageStrings.revertUncommittedLine : DiffPageStrings.revertUnstagedLine,
                     DiffPageStrings.revertTrashLine]
        if files > 1 || request.paths.count > 1 {
            lines += request.paths.prefix(Self.listed)
            if request.paths.count > Self.listed {
                lines.append(String(format: DiffPageStrings.revertAndMore, request.paths.count - Self.listed))
            }
        }
        self.lines = lines
        confirm = DiffPageStrings.revertButton
    }
}

/// Shows the Revert sheet over the tab (native, so page script cannot answer it); true when the
/// person chose Revert.
public typealias DiffRevertConfirming = @MainActor (DiffRevertPrompt) async -> Bool

/// A hunk the tab reverted: the token the page's Undo names, the repository it was in, and the way
/// back. Only the host holds the patch, so Undo never writes text the page sent.
struct DiffRevertUndo: Equatable {
    let token: String
    let repository: String
    let undo: AgentPaneGitDiscard.Undo
}

/// The tab's revert bookkeeping: the hunks Undo can still put back (newest last, bounded), the
/// gesture the last revert spent, and whether a revert runs now.
struct DiffRevertState {
    static let maximumUndos = 20
    static let maximumUndoBytes = 4 << 20

    private(set) var undos: [DiffRevertUndo] = []
    /// The key or mouse event (its `systemUptime`) the last revert spent: one event, one revert.
    var spentGesture: TimeInterval?
    var running = false

    mutating func push(_ undo: DiffRevertUndo) {
        undos.append(undo)
        while undos.count > Self.maximumUndos || undos.reduce(0, { $0 + $1.undo.patch.utf8.count }) > Self.maximumUndoBytes {
            undos.removeFirst()
        }
    }

    /// Removes and answers the hunk `token` names, when it was reverted in `repository`.
    mutating func take(_ token: String, in repository: String) -> DiffRevertUndo? {
        guard let index = undos.firstIndex(where: { $0.token == token && $0.repository == repository }) else { return nil }
        return undos.remove(at: index)
    }

    /// A new repository: nothing reverted in the old one can come back here.
    mutating func reset() {
        undos.removeAll()
    }
}

/// The diff tab's Revert (D3, the Codex Review pane's revert): `cmux.diff.git.discard {paths, scope,
/// sources?}` reverts whole files after the native sheet (``confirmRevert``; `sources` names the
/// paths that are a rename's previous path, so the sheet counts that file once), `cmux.diff.git.
/// discardHunk {paths, scope, hunk}` one hunk at once and answers `{undo}`, and `cmux.diff.git.
/// undoDiscard {undo}` puts that hunk back (each of the last ``DiffRevertState/maximumUndos``, once,
/// in the repository it came from, while the file is as the revert left it). `scope` is `unstaged`
/// (back to the index) or `uncommitted` (back to HEAD). As for Stage, each runs in the tab's own
/// repository whatever `cwd` the page sends. Each needs its own key or mouse event in the page (one
/// event, one revert), and one runs at a time.
extension DiffPageProvider {
    static let revertOps: Set<String> = ["cmux.diff.git.discard", "cmux.diff.git.discardHunk", "cmux.diff.git.undoDiscard"]

    /// Answers a revert op; nil for any other op.
    func revertCall(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue? {
        guard Self.revertOps.contains(op) else { return nil }
        guard let reverter = git as? any DiffGitReverting else { throw PageError.unknownOp(op) }
        guard context.userGesture, let event = context.gestureEvent, event != revertState.spentGesture else {
            throw PageError(code: "transport.gesture_required", message: DiffPageStrings.revertNeedsGesture)
        }
        guard !revertState.running else { throw PageError(code: "git.busy", message: DiffPageStrings.revertBusy, retryable: true) }
        revertState.spentGesture = event
        revertState.running = true
        defer { revertState.running = false }
        let repository = try await gitRepository()
        if op == "cmux.diff.git.undoDiscard" {
            guard let token = params["undo"]?.stringValue, let entry = revertState.take(token, in: repository) else {
                throw PageError(code: "git.failed", message: DiffPageStrings.revertUndoGone)
            }
            if let message = await reverter.reapply(entry.undo, in: repository) { throw PageError(code: "git.failed", message: message) }
            return ["ok": true]
        }
        var fields = (params.objectValue ?? [:]).mapValues(\.foundationObject)
        fields["cwd"] = repository
        guard let request = AgentPaneGitDiscard(method: "git." + op.dropFirst("cmux.diff.git.".count), params: fields) else {
            throw PageError.invalidParams(AgentPaneGitDiscard.invalidMessage)
        }
        if request.hunk == nil {
            let sources = Set(params["sources"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            guard sources.isSubset(of: request.paths) else { throw PageError.invalidParams(AgentPaneGitDiscard.invalidMessage) }
            guard let confirmRevert, await confirmRevert(DiffRevertPrompt(request, sources: sources)) else { throw PageError.cancelled }
        }
        switch await reverter.discard(request, in: repository) {
        case .failed(let message):
            throw PageError(code: "git.failed", message: message)
        case .reverted(let undo):
            guard let undo else { return ["ok": true] }
            let entry = DiffRevertUndo(token: UUID().uuidString.lowercased(), repository: repository, undo: undo)
            revertState.push(entry)
            return ["ok": true, "undo": .string(entry.token)]
        }
    }
}

extension DiffAgentGit: DiffGitReverting {
    public func discard(_ request: AgentPaneGitDiscard, in repository: String) async -> AgentPaneGitDiscard.Outcome {
        await AgentPaneGitDiscard.run(request, roots: [repository])
    }

    public func reapply(_ undo: AgentPaneGitDiscard.Undo, in repository: String) async -> String? {
        await AgentPaneGitDiscard.reapply(undo, cwd: repository, roots: [repository])
    }
}
