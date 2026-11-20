public import CmuxNextSettings
public import Foundation

/// What a diff tab has once its repository is known: the grant its sidecar
/// requests run under, the config its page boots from, and the chat turn its
/// Last turn scope shows (nil: the tab offers none).
public nonisolated struct DiffTabReady: Sendable {
    let grant: DiffSessionGrant
    let config: JSONValue
    var turn: DiffTurn?
    /// The chat's own patch the tab shows instead of a repository (``DiffChatPatch``).
    var chatPatch: DiffChatPatch?
    /// The session precomputed for it when an agent's turn ended (DiffPageRuntime+Warm.swift).
    var warm: DiffWarmSession?
}

/// A chat turn's changes as the chat built them from its tool calls, for a folder in no repository
/// or a turn that wrote a file outside it, where no git source holds them: unified patch `text`, and
/// the patch's name of the `file` the tab scrolls to, and the `title` of its tab (the chat folder's
/// name). Its tab shows only this patch, read-only, and reads no disk and no repository
/// (``DiffPageProvider/chatPatch``).
public nonisolated struct DiffChatPatch: Sendable, Hashable {
    public let text: String
    public let file: String?
    public let title: String

    /// `folder`: the chat's, which names the tab; the diff viewer's own title without one.
    public init(text: String, file: String? = nil, folder: String? = nil) {
        self.text = text
        self.file = file
        let name = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        title = name.isEmpty || name == "/" ? DiffPageStrings.tabTitle : name
    }
}

/// Why a diff tab has no grant (shown by the page as its status message).
public nonisolated struct DiffTabFailure: Error, Sendable, Equatable {
    let title: String
    let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// What a diff tab asks of its owner (``DiffPageService``) for the empty state
/// (diff-host.md "Empty state"): find a folder's repository, make a grant for
/// it, the recents, the folder picker, and "this tab now shows `repository`"
/// (which records the recent and retitles the tab), and opening a file of the
/// tab's repository (`cmux.diff.openFile`, checked by the provider first).
public protocol DiffTabHosting: AnyObject {
    func repository(at folder: URL) async -> DiffRepository?
    func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error>
    func recents() async -> JSONValue
    func chooseFolder(start: URL?) async -> URL?
    func opened(_ repository: DiffRepository, source: DiffOpenSource)
    /// Opens `file` (a real file inside the tab's repository) at `target`, at 1-based `line`
    /// when the target can show one. False when nothing opened.
    func openFile(_ file: URL, line: Int?, target: DiffFileTarget) -> Bool
    /// The chat turn the tab's Last turn shows now in `repository` (a header's Changes gives the
    /// tab its chat's newer turn), nil for none.
    func turn(for repository: String) -> DiffTurn?
}

extension DiffTabHosting {
    /// A host without chat turns.
    public func turn(for repository: String) -> DiffTurn? { nil }
}
