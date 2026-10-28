import AppKit
import CmuxNextDesign
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// What a file page tab asks of its owner (``FilePageService``): the workspace roots, the
/// recents and picker, the look (settings section, theme.css), preference writes, and where a
/// followed link opens.
protocol FilePageHosting: AnyObject {
    var roots: FileWorkspaceRoots { get }
    /// `markdown.remoteImages`: load web images without a per-document click (default false).
    var remoteImages: Bool { get }
    /// `{home, items: [{path, name?, openedAt}]}` (diff-host.md "Empty state").
    func recents() -> JSONValue
    func record(_ url: URL)
    func chooseFile(start: URL?) async -> URL?
    /// `{settings?, themeCSS?, syntaxTheme?, languages?, screenReader?}`.
    func look() -> JSONValue
    func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void
    /// Writes one `<section>.<key>` setting (PAGE-PREFS) as `writer`.
    func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws
    /// The tab now shows `url` (its title follows the file).
    func opened(_ url: URL)
    /// http(s) in a cmux browser tab; mailto: and tel: through the system handler.
    func openExternal(_ url: URL)
    /// Another file, through the file routing (its own page tab).
    func openFile(_ url: URL)
    /// A cmux app link (`cmux://workspace/ws_…` and the other deep links) opened inside this app,
    /// never through the system; false when the app does not open it.
    func openAppLink(_ url: URL) -> Bool
    /// Whether `path` (canonical) is a recents entry the user opened.
    func isRecent(_ path: String) -> Bool
    /// The native "Open <path>?" sheet for a link outside every granted document's folder: shown
    /// only after a real user gesture, one at a time; false when refused or not shown.
    func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool
    /// The native omnibar shows the file's path above the page (the Markdown omnibar), so the
    /// page's toolbar drops its own file name (config `omnibar: true`).
    var showsOmnibar: Bool { get }
    /// The page's link history moved (`cmux.markdown.history`): the omnibar's Back and Forward follow.
    func historyChanged(canBack: Bool, canForward: Bool)
    /// A page's edit of `url` (the R96 quit hook): the document's unsaved state and its draft.
    func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance
    /// A normal save of `url` wrote `hash`.
    func saved(_ url: URL, hash: String)
}

extension FilePageHosting {
    var showsOmnibar: Bool { false }
    func historyChanged(canBack: Bool, canForward: Bool) {}
}

/// One file page tab's `cmux.markdown.*` or `cmux.editor.*` namespace (diff-host.md S6 "Markdown
/// page contract", "Editor page"). The tab has one file at a time (none: the empty state); the
/// provider reads and saves it with ``FileDocument``, watches it with ``FileChangeWatch`` for the
/// `changes` stream, and serves the markdown page's images and libraries
/// (``PageDynamicResourceSource``).
final class FilePageProvider: PageProvider, PageDynamicResourceSource {
    let kind: FilePageKind
    private(set) var file: URL?
    /// Strong: the tab host holds its service weakly, so no cycle.
    private(set) var host: (any FilePageHosting)?
    /// The app's deadline scheduler and lanes: the file's change watch debounces on the one and reads on the other;
    /// link checks, `[[` listings, local images and libraries read on the lanes too.
    private let deadlines: MainDeadlineScheduler
    let work: BackgroundWork
    let libraries: URL?
    let images: any RemoteImageFetching
    private var watch: FileChangeWatch?
    private var changeListeners: [UUID: (JSONValue) -> Void] = [:]
    /// The folder of the open file the current asset token serves, and the token.
    private(set) var assetToken = UUID().uuidString.lowercased()
    /// The unguessable resource prefix for this document. It rotates on navigation so an approved
    /// document cannot keep fetching after the tab starts showing another one.
    private(set) var remoteImageToken = UUID().uuidString.lowercased()
    /// A click in the page approved web images for the document currently shown in this tab.
    private var remoteImagesApproved = false
    /// What the page may open and save, file by file (``FileWorkspaceRoots/Grants``).
    private(set) var access = FileWorkspaceRoots.Grants()
    /// A recovered crash draft of the tab's file: the next config carries it once (the markdown and
    /// editor pages load it as an unsaved edit).
    var recoveredText: String?
    /// Where the editor puts the cursor on the tab's file (a Find result's line and column): the
    /// next config of that file carries it once as `reveal`. The markdown page ignores it.
    var reveal: FilePosition?
    /// What the tab's previous page showed before it was discarded (its `cmux.<page>.viewState`
    /// answer): the next config of the tab's file carries it once as `viewState`.
    var viewState: JSONValue?
    /// Whether the tab's file may be saved (the last config's answer).
    private var writable = false
    var isWritable: Bool { writable }
    /// The page shows its file read only (the last config said `readOnly`): bare keys are the
    /// user's bindings there, not typing (`markdownReadOnlyFocused`, K1).
    private(set) var showsReadOnly = false
    private(set) var isClosed = false
    /// Where the markdown page keeps table column widths between opens (nil: the page keeps
    /// none past the tab). ``FilePageProvider+TableWidths.swift``.
    let tableWidths: (any MarkdownTableWidthStoring)?
    /// Where the markdown page's viewer comments live between opens (nil: none are kept).
    /// ``FilePageProvider+Comments.swift``.
    let comments: (any MarkdownCommentStoring)?
    /// Sends the page a changed comment list (the service sets it: the `comments` page command).
    var onCommentsChanged: ((JSONValue) -> Void)?
    /// The newest persisted comment mutation already published to this page. A later callback can
    /// finish parsing before an older one, so stale mutations must not overwrite the page.
    var latestCommentsSequence = 0
    /// The table the page last reported under a right-click (its index), for the native menu's
    /// Reset Column Widths; nil when the right-click was outside every table.
    var contextTable: Int?

    static let preferenceValueLimit = 2048
    nonisolated static let listLimit = 50

    /// `userChose`: the user opened the tab's document (Open File..., the picker, a click), so it
    /// is granted and writable; in the code editor, a document an agent or script opened is the
    /// page's to show, and writable only inside a root the user chose. `readOnly`: the host opens
    /// the document read only whoever opened it (a chat transcript). `access`: the tab's previous
    /// provider's, for a tab made again after a discard; it replaces `userChose` and `readOnly`.
    init(kind: FilePageKind, file: URL?, userChose: Bool = true, readOnly: Bool = false, access: FileWorkspaceRoots.Grants? = nil,
         host: any FilePageHosting, libraries: URL?,
         images: any RemoteImageFetching, tableWidths: (any MarkdownTableWidthStoring)? = nil,
         comments: (any MarkdownCommentStoring)? = nil,
         deadlines: MainDeadlineScheduler,
         work: BackgroundWork = BackgroundWork(label: "files.page")) {
        self.deadlines = deadlines
        self.work = work
        self.kind = kind
        self.tableWidths = tableWidths
        self.comments = comments
        self.file = file.map(Self.canonical)
        if let access {
            self.access = access
            if let file = self.file { self.access.shown.insert(file.path) }
        } else if let file = self.file {
            self.access = FileWorkspaceRoots.Grants(file: file.path, userChose: userChose, readOnly: readOnly)
        }
        self.host = host
        self.libraries = libraries
        self.images = images
    }

    /// The tab shows the empty state.
    var isPicking: Bool { file == nil && !isClosed }

    /// When the editor reported that Monaco waits for the second key of a sequence
    /// (`cmux.editor.keySequence`), in `uptime()` seconds; nil when none is pending.
    private var keySequenceStarted: TimeInterval?
    /// The clock for ``keySequencePending`` (seconds since boot); tests replace it.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// How long a pending sequence holds the next key, if the page never reports its end.
    nonisolated static let keySequenceLimit: TimeInterval = 5

    /// The editor waits for the second key of a key sequence: the app's key dispatcher lets the
    /// next key reach it. A report older than ``keySequenceLimit`` no longer counts.
    var keySequencePending: Bool {
        guard let started = keySequenceStarted else { return false }
        return uptime() - started < Self.keySequenceLimit
    }

    private var origin: String { kind.descriptor.origin }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard !isClosed, let host else { throw PageError.closed }
        switch op {
        case kind.op("config"):
            guard let file else { return merged(["pick": true], host.look()) }
            return try await config(for: file)
        case kind.op("open"):
            return try await open(path(params["path"]))
        case kind.op("history") where kind == .markdown:
            host.historyChanged(canBack: params["canBack"]?.boolValue ?? false, canForward: params["canForward"]?.boolValue ?? false)
            return .object([:])
        case kind.op("edited"):
            return try edited(params, host: host)
        case kind.op("save"):
            return try await save(params)
        case kind.op("setPreference"):
            try await setPreference(params, host: host, userGesture: context.userGesture)
            return .object([:])
        case kind.op("loadRemoteImages") where kind == .markdown:
            guard context.userGesture else {
                throw PageError(code: "cmux.page.gesture", message: "loading web images needs a user gesture")
            }
            let requested = try path(params["path"])
            guard let file, Self.canonical(requested) == file else {
                throw PageError.invalidParams("path is not this page's file")
            }
            remoteImagesApproved = true
            return ["remoteImageBase": .string(remoteImageBase)]
        case kind.op("recents"):
            return host.recents()
        case kind.op("chooseFile"):
            let start = params["start"]?.stringValue.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            guard let chosen = await host.chooseFile(start: start) else { return .null }
            userChose(chosen)
            return ["path": .string(chosen.path)]
        case kind.op("openLink"):
            try await openLink(params, host: host, userGesture: context.userGesture)
            return .object([:])
        case kind.op("keySequence") where kind == .editor:
            keySequenceStarted = params["pending"]?.boolValue == true ? uptime() : nil
            return .object([:])
        case kind.op("resolveLinks") where kind == .markdown:
            return try await resolveLinks(params, host: host)
        case kind.op("listFiles") where kind == .markdown:
            return try await listFiles(params)
        case kind.op("setTableWidths") where kind == .markdown:
            return try await setTableWidths(params)
        case kind.op("deleteComment") where kind == .markdown:
            return try await deleteComment(params)
        case kind.op("contextTable") where kind == .markdown:
            contextTable = params["table"]?.intValue.flatMap { $0 >= 0 ? $0 : nil }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard !isClosed, let host else { throw PageError.closed }
        switch stream {
        case kind.op("changes"):
            let id = UUID()
            changeListeners[id] = onEvent
            // Each event carries the file's whole text and hash (or its deletion): the newest replaces the rest.
            return PageSubscription(frozenDelivery: .latest) { [weak self] in self?.changeListeners[id] = nil }
        case kind.op("look"):
            let stop = host.listenLook(onEvent)
            // Each event names only the look keys that changed (FilePageLook.publish: the settings and syntax
            // theme, each theme.css save with its whole text, the imported editor's settings files, the
            // language packs), and the page merges them with no re-read on a gap: none may drop.
            return PageSubscription(frozenDelivery: .ordered) { stop() }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    // MARK: Files

    func path(_ value: JSONValue?) throws -> URL {
        guard let path = value?.stringValue, path.hasPrefix("/"), !path.contains("\u{0}") else {
            throw PageError.invalidParams("path must be absolute")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Writable: every markdown document the page shows, whoever opened it and in whatever
    /// workspace (user 2026-10-18: "All markdown viewers should be read-write"); in the code editor,
    /// a document the user granted or a file inside a folder the user chose as a root. A file that
    /// is binary, not UTF-8 or not writable stays read only either way (``FileDocument/read``).
    private func inWorkspace(_ url: URL) -> Bool {
        if kind == .markdown { return true }
        let path = Self.canonical(url).path
        return access.granted.contains(path) || (host?.roots.contains(path) ?? false)
    }

    /// Links resolved, `.` and `..` removed: the path every grant check compares.
    nonisolated static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// The user chose `url` for this tab (a picker result, or Open File... of the file it shows):
    /// a document of the tab, and writable.
    func userChose(_ url: URL) {
        let path = Self.canonical(url).path
        access.documents.insert(path)
        access.granted.insert(path)
    }

    /// Whether `url` (canonical) is inside the folder of one of the tab's documents.
    private func inGrantedFolder(_ url: URL) -> Bool {
        access.documents.contains { document in
            let folder = URL(fileURLWithPath: document).deletingLastPathComponent().path
            return url.path.hasPrefix(folder == "/" ? "/" : folder + "/")
        }
    }

    /// `open` takes only a granted path: the tab's document, a chooseFile result, an approved
    /// link, a recents entry, or a markdown file `resolveLinks` found in a granted folder.
    private func mayOpen(_ url: URL) -> Bool {
        let path = url.path
        return access.documents.contains(path) || access.shown.contains(path) || access.linked.contains(path) || (host?.isRecent(path) ?? false)
    }

    private func snapshot(_ url: URL) async throws -> FileSnapshot {
        do {
            let file = try await Self.read(url, inWorkspace: inWorkspace(url.resolvingSymlinksInPath()))
            guard file.readOnlyReason == nil, access.readOnlyDocuments.contains(file.url.path) else { return file }
            return FileSnapshot(url: file.url, text: file.text, hash: file.hash, size: file.size, readOnlyReason: .transcript)
        } catch .notFound {
            throw PageError(code: kind.op("not_found"), message: url.path)
        } catch .notFile {
            throw PageError(code: kind == .markdown ? kind.op("not_markdown") : kind.op("not_file"), message: url.path)
        } catch {
            throw PageError(code: kind.op("too_large"), message: url.path)
        }
    }

    /// `cmux.<page>.open {path}`: the tab's file from now on (empty state, a followed link).
    func open(_ url: URL) async throws -> JSONValue {
        // The grant comes first, so a refused path says nothing about the file.
        guard mayOpen(Self.canonical(url)) else { throw PageError(code: kind.op("forbidden"), message: url.path) }
        guard kind.accepts(url) else { throw PageError(code: kind.op("not_markdown"), message: url.path) }
        let opened = try await snapshot(url)
        guard !isClosed else { throw PageError.closed }
        // A link the page followed in place is shown, not granted: writable only in a root.
        if access.granted.contains(opened.url.path) || host?.isRecent(opened.url.path) == true { access.granted.insert(opened.url.path) }
        access.shown.insert(opened.url.path)
        if opened.url != file {
            file = opened.url
            assetToken = UUID().uuidString.lowercased()
            remoteImageToken = UUID().uuidString.lowercased()
            remoteImagesApproved = false
            restartWatch(known: opened.hash)
        }
        host?.record(opened.url)
        host?.opened(opened.url)
        return await config(opened)
    }

    private func config(for url: URL) async throws -> JSONValue {
        let file = try await snapshot(url)
        // A tab made with its file starts watching on its first config.
        if file.url == self.file, watch == nil { restartWatch(known: file.hash) }
        return await config(file)
    }

    private func config(_ file: FileSnapshot) async -> JSONValue {
        var config: [String: JSONValue] = ["path": .string(file.url.path), "text": .string(file.text), "hash": .string(file.hash)]
        writable = file.readOnlyReason == nil
        if let recovered = recoveredText, file.url == self.file {
            recoveredText = nil
            config["recoveredText"] = .string(recovered)
        }
        if kind == .editor, let reveal, file.url == self.file {
            self.reveal = nil
            config["reveal"] = reveal.jsonValue
        }
        if let viewState, file.url == self.file {
            self.viewState = nil
            config["viewState"] = viewState
        }
        if let reason = file.readOnlyReason {
            config["readOnly"] = true
            config["readOnlyReason"] = .string(reason.rawValue)
        }
        switch kind {
        case .markdown:
            config["assetBase"] = .string("\(origin)/\(MarkdownPageResource.asset)/\(assetToken)/")
            config["libBase"] = .string("\(origin)/\(MarkdownPageResource.library)/")
            if host?.showsOmnibar == true { config["omnibar"] = true }
            if remoteImagesAllowed { config["remoteImageBase"] = .string(remoteImageBase) }
            if let repository = await AgentPaneGitHubRepository.read(at: file.url.deletingLastPathComponent().path) {
                config["githubRepository"] = .string(repository)
            }
            // Read before the page's first layout, so a saved table never jumps from its natural width.
            if let widths = await savedTableWidths(file.url) { config["tableWidths"] = widths }
            if let comments = await savedComments(file.url) { config["comments"] = comments }
        case .editor:
            config["size"] = JSONValue(file.size)
        }
        // Set after the awaits above, so overlapping opens leave the flag
        // matching the config the page applies last.
        showsReadOnly = file.readOnlyReason != nil
        return merged(.object(config), host?.look() ?? .object([:]))
    }

    private func merged(_ base: JSONValue, _ look: JSONValue) -> JSONValue {
        var members = look.objectValue ?? [:]
        for (key, value) in base.objectValue ?? [:] { members[key] = value }
        return .object(members)
    }

    /// Remote images are automatic only by explicit setting; otherwise a click approves this
    /// document for the lifetime of its tab entry.
    var remoteImagesAllowed: Bool { remoteImagesApproved || host?.remoteImages == true }

    private var remoteImageBase: String {
        "\(origin)/\(MarkdownPageResource.remoteImage)/\(remoteImageToken)/"
    }

    private func save(_ params: JSONValue) async throws -> JSONValue {
        let url = try path(params["path"])
        guard let file, url.resolvingSymlinksInPath() == file else { throw PageError.invalidParams("path is not this page's file") }
        guard let text = params["text"]?.stringValue else { throw PageError.invalidParams("text is required") }
        let base: String?
        switch params["baseHash"] {
        case .string(let hash)?: base = hash
        case .null?, nil: base = nil
        default: throw PageError.invalidParams("baseHash must be a string or null")
        }
        guard !access.readOnlyDocuments.contains(file.path) else { throw PageError(code: kind.op("read_only"), message: file.path) }
        let workspace = inWorkspace(file)
        let result: FileSaveResult
        do {
            result = try await Self.write(text, to: file, baseHash: base, inWorkspace: workspace)
        } catch .readOnly {
            throw PageError(code: kind.op("read_only"), message: file.path)
        } catch .conflict(let hash, let text) {
            throw PageError(code: kind.op("conflict"), message: file.path, details: ["hash": .string(hash), "text": .string(text)])
        } catch .deleted {
            throw PageError(code: kind.op("conflict"), message: file.path, details: ["hash": .null, "deleted": true])
        } catch .failed(let reason) {
            throw PageError(code: kind.op("save_failed"), message: reason, retryable: true)
        }
        host?.saved(file, hash: result.hash)
        return ["hash": .string(result.hash)]
    }

    @concurrent private static func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot {
        try FileDocument.read(url, inWorkspace: inWorkspace)
    }

    @concurrent private static func write(_ text: String, to url: URL, baseHash: String?,
                                          inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try FileDocument.save(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }

    private func restartWatch(known: String? = nil) {
        watch?.stop()
        watch = nil
        guard let file, !isClosed else { return }
        let watch = FileChangeWatch(url: file, inWorkspace: { [weak self] in self?.inWorkspace(file) ?? false }, deadlines: deadlines,
                                    work: work) { [weak self] snapshot in
            self?.publishChange(snapshot, of: file)
        }
        watch.knownHash = known
        self.watch = watch
        watch.start()
    }

    private func publishChange(_ snapshot: FileSnapshot?, of url: URL) {
        guard url == file else { return }
        let event: JSONValue = if let snapshot {
            ["path": .string(url.path), "hash": .string(snapshot.hash), "text": .string(snapshot.text)]
        } else {
            ["path": .string(url.path), "hash": .null, "deleted": true]
        }
        for id in changeListeners.keys.sorted(by: { $0.uuidString < $1.uuidString }) { changeListeners[id]?(event) }
    }

    /// `cmux.<page>.edited {path, text, baseHash}`: the tab's file was edited (the quit hook).
    private func edited(_ params: JSONValue, host: any FilePageHosting) throws -> JSONValue {
        let url = try path(params["path"])
        guard let file, Self.canonical(url) == file else { throw PageError.invalidParams("path is not this page's file") }
        guard let text = params["text"]?.stringValue else { throw PageError.invalidParams("text is required") }
        let accepted = host.edited(file, text: text, baseHash: params["baseHash"]?.stringValue, writable: writable)
        switch accepted {
        case .kept: return ["recovery": "kept"]
        case .tooLarge: return ["recovery": "tooLarge"]
        case .invalidID: return ["recovery": "invalidID"]
        }
    }

    // MARK: Preferences

    /// `cmux.<page>.setPreference {key, value}`: one `<section>.<dotted key>` (PAGE-PREFS).
    private func setPreference(_ params: JSONValue, host: any FilePageHosting, userGesture: Bool) async throws {
        guard let key = params["key"]?.stringValue, Self.isPreferenceKey(key, section: kind.section) else {
            throw PageError.invalidParams("key must be a \(kind.section).* setting")
        }
        let value = params["value"] ?? .null
        guard value.compactText.utf8.count <= Self.preferenceValueLimit else { throw PageError.invalidParams("value is too large") }
        // The user's own write only for a call backed by a real gesture; else the page's.
        try await host.setPreference(key: key, value: value, by: userGesture ? .user : .caller("page"))
    }

    // MARK: Links

    private func openLink(_ params: JSONValue, host: any FilePageHosting, userGesture: Bool) async throws {
        guard let href = params["href"]?.stringValue else { throw PageError.invalidParams("href is required") }
        if kind == .markdown, params["kind"]?.stringValue == "file" {
            let target = Self.canonical(try path(params["target"]))
            // A stat can hang on a network or sleeping volume: never on the main actor.
            let exists = (try? await work.runFiles(.userBlocking) { FileManager.default.fileExists(atPath: target.path) }) ?? false
            guard exists else { throw PageError(code: kind.op("not_found"), message: target.path) }
            // Inside a granted document's folder (links resolved): opens. Anything else asks,
            // naming the resolved path; a refused or unshown sheet refuses the link.
            if !inGrantedFolder(target) {
                guard await host.confirmOpen(target, userGesture: userGesture) else { throw PageError.cancelled }
                userChose(target)
            }
            return host.openFile(target)
        }
        if params["kind"]?.stringValue == "app" {
            // A cmux deep link opens inside the app or not at all; it never reaches the system.
            guard let url = URL(string: href), host.openAppLink(url) else {
                throw PageError.invalidParams("not a cmux link this app opens")
            }
            return
        }
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else {
            throw PageError.invalidParams("links open only http(s), mailto: and tel:")
        }
        host.openExternal(url)
    }

    private func resolveLinks(_ params: JSONValue, host: any FilePageHosting) async throws -> JSONValue {
        let from = try path(params["from"])
        var relatives: [String] = []
        for case .string(let relative) in (params["paths"]?.arrayValue ?? []).prefix(500) { relatives.append(relative) }
        // The symlink resolution and existence checks run off the main actor; the grants stay here.
        let file = file, roots = host.roots, paths = relatives
        let found = try await work.runFiles(.userVisible) { try Self.resolve(paths, from: from, file: file, roots: roots) }
        for path in found.markdown where inGrantedFolder(URL(fileURLWithPath: path)) { access.linked.insert(path) }
        return ["links": .object(found.links)]
    }

    // MARK: Teardown

    func close() {
        isClosed = true
        watch?.stop()
        watch = nil
        changeListeners.removeAll()
        host = nil
    }
}
