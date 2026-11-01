import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Where `cmux.diff.openFile` takes a file of the tab's repository.
public nonisolated enum DiffFileTarget: String, Equatable, Sendable {
    /// A cmux file tab (the editor or the Markdown page) beside the diff tab, at the line if given.
    case tab
    /// The editor app the agent pane's "Open in editor" uses.
    case editor
    /// The file, selected in Finder.
    case finder
}

/// One `cmux.diff.openFile {path, line?, where?}` request, checked: `path` is relative to the
/// repository's top level (the diff's own file names), `line` a 1-based line of the file as it is
/// now, `where` a ``DiffFileTarget`` (default `tab`).
nonisolated struct DiffFileOpenRequest: Equatable, Sendable {
    /// The longest line number a request may carry (the file pages' own bound).
    static let maximumLine = 10_000_000
    /// The longest path a request may carry, in bytes.
    static let maximumPathBytes = 4096

    let path: String
    let line: Int?
    let target: DiffFileTarget

    init(path: String, line: Int? = nil, target: DiffFileTarget = .tab) {
        self.path = path
        self.line = line
        self.target = target
    }

    init(_ params: JSONValue) throws(PageError) {
        guard let path = params["path"]?.stringValue, Self.isRepositoryPath(path) else {
            throw PageError.invalidParams("path must name a file relative to the repository")
        }
        var line: Int?
        if let value = params["line"], value != .null {
            guard let number = value.intValue, (1...Self.maximumLine).contains(number) else {
                throw PageError.invalidParams("line must be a whole number from 1 to \(Self.maximumLine)")
            }
            line = number
        }
        var target = DiffFileTarget.tab
        if let value = params["where"], value != .null {
            guard let name = value.stringValue, let chosen = DiffFileTarget(rawValue: name) else {
                throw PageError.invalidParams("where must be tab, editor or finder")
            }
            target = chosen
        }
        self.init(path: path, line: line, target: target)
    }

    /// A path relative to the repository's top level that names no folder above it and nothing in
    /// git's own folder: not empty, not absolute or `~`, no empty, `.`, `..` or `.git` part, no NUL.
    /// The diff never lists a file under `.git`, so no click needs one (its hooks and config stay out).
    static func isRepositoryPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= maximumPathBytes, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\u{0}") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git"
        }
    }
}

/// Open the file from the diff (D4): the page's file name, its "Open file" menu rows and a
/// Cmd-click on a diff line call `cmux.diff.openFile`. The file must be in the tab's own
/// repository, the one its grant covers, after symlinks: a page can never open a file outside it.
/// It must exist (a deleted file has nothing to open), and each open spends one real click or key
/// in the page (``PageCallContext/gestureEvent``), so a script cannot open file after file on one
/// gesture. The tab's host opens it (``DiffTabHosting``).
///
/// Accepted risk: the file is checked, then opened by its real path, and the page that shows it
/// reads it again. A process that can write the repository could swap it for a link in between;
/// that process already has the person's access, and the chat's `file.open` has the same window.
extension DiffPageProvider {
    static let openFileOp = "cmux.diff.openFile"
    static let openFileNotFound = "cmux.diff.file_not_found"
    static let openFileFailed = "cmux.diff.open_failed"

    /// Answers `cmux.diff.openFile`; nil for any other op.
    func openFileCall(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue? {
        guard op == Self.openFileOp else { return nil }
        // A remote chat's files have no tab that reads them; a Cloud workspace's do (#25581).
        guard !remote || machine != nil else {
            throw PageError(code: "remoteOpenUnavailable", message: "Opening files from a remote chat is unavailable")
        }
        guard let host else { throw PageError.unknownOp(op) }
        // One open per gesture: the gesture's time must be newer than the last one an open spent.
        guard context.userGesture, let gesture = context.gestureEvent, gesture > (spentOpenGesture ?? -.infinity) else {
            throw PageError(code: "transport.gesture_required", message: "Opening a file needs a click or a key in the page.")
        }
        spentOpenGesture = gesture
        let request = try DiffFileOpenRequest(params)
        guard let ready else { throw PageError(code: "sidecarUnavailable", message: "No repository is open") }
        let repository: String
        do {
            repository = try await ready.value.grant.repository
        } catch let failure as DiffTabFailure {
            throw PageError(code: "sidecarUnavailable", message: failure.message)
        }
        let file: URL
        if remote {
            // The machine's file tab reads the file there and says so when it is gone. The editor
            // app and Finder would open a path of this Mac.
            guard request.target == .tab else {
                throw PageError(code: "remoteOpenUnavailable", message: DiffPageStrings.machineUnsupported)
            }
            file = URL(fileURLWithPath: repository, isDirectory: true).appending(path: request.path).standardizedFileURL
        } else {
            guard let found = await Self.repositoryFile(request.path, in: repository) else {
                throw PageError(code: Self.openFileNotFound, message: request.path)
            }
            file = found
        }
        guard !isClosed, host.openFile(file, line: request.line, target: request.target) else {
            throw PageError(code: Self.openFileFailed, message: request.path)
        }
        return ["ok": true]
    }

    /// `config` listing `cmux.diff.openFile`, when this tab has a host that opens files.
    func withOpenFile(_ config: JSONValue) -> JSONValue {
        guard !remote || machine != nil, host != nil, case .object(var members) = config, members["pick"] == nil else { return config }
        members["ops"] = .array((members["ops"]?.arrayValue ?? []) + [.string(Self.openFileOp)])
        return .object(members)
    }

    /// The existing regular file `path` names in `repository`, its symlinks resolved, or nil
    /// when it is missing, not a regular file, or outside the repository's real folder.
    /// Blocking file IO, so off the main actor.
    @concurrent nonisolated static func repositoryFile(_ path: String, in repository: String) async -> URL? {
        guard DiffFileOpenRequest.isRepositoryPath(path), repository.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: repository, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let file = AgentPaneFileOpen.resolve(root.appending(path: path).path), file.path.hasPrefix(prefix),
              // A link inside the repository may still point into git's own folder.
              DiffFileOpenRequest.isRepositoryPath(String(file.path.dropFirst(prefix.count))) else { return nil }
        return file
    }
}
