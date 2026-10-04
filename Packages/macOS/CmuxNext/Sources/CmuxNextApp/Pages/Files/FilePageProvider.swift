import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// What a file page tab asks of its owner (``FilePageService``): the workspace roots, the
/// recents and picker, the look (settings section, theme.css), preference writes, and where a
/// followed link opens.
protocol FilePageHosting: AnyObject {
    var roots: FileWorkspaceRoots { get }
    /// `markdown.remoteImages` (default true).
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
    /// Whether `path` (canonical) is a recents entry the user opened.
    func isRecent(_ path: String) -> Bool
    /// The native "Open <path>?" sheet for a link outside every granted document's folder: shown
    /// only after a real user gesture, one at a time; false when refused or not shown.
    func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool
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
    private let clock: any Clock<Duration>
    let libraries: URL?
    let images: any RemoteImageFetching
    private var watch: FileChangeWatch?
    private var changeListeners: [UUID: (JSONValue) -> Void] = [:]
    /// The folder of the open file the current asset token serves, and the token.
    private(set) var assetToken = UUID().uuidString.lowercased()
    /// Canonical paths the user granted this tab: its document, chooseFile results, approved
    /// links. The page opens only these (and recents); their folders bound links that open
    /// without asking, and they are writable (the user chose them).
    private(set) var granted: Set<String> = []
    /// Markdown files `resolveLinks` found inside a granted document's folder: the page may open
    /// them in place (following a link it showed).
    private var linked: Set<String> = []
    /// Documents this tab has shown (it may reopen them, its own back and forward).
    private var shown: Set<String> = []
    private(set) var isClosed = false

    static let preferenceValueLimit = 2048
    static let listLimit = 50

    /// `userChose`: the user opened the tab's document (Open File..., the picker, a click), so it
    /// is granted and writable; a document an agent or script opened is the page's to show, and
    /// writable only inside a root the user chose.
    init(kind: FilePageKind, file: URL?, userChose: Bool = true, host: any FilePageHosting, clock: any Clock<Duration> = ContinuousClock(),
         libraries: URL?, images: any RemoteImageFetching) {
        self.kind = kind
        self.file = file.map(Self.canonical)
        if let file = self.file {
            shown.insert(file.path)
            if userChose { granted.insert(file.path) }
        }
        self.host = host
        self.clock = clock
        self.libraries = libraries
        self.images = images
    }

    /// The tab shows the empty state.
    var isPicking: Bool { file == nil && !isClosed }

    private var origin: String { kind.descriptor.origin }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard !isClosed, let host else { throw PageError.closed }
        switch op {
        case kind.op("config"):
            guard let file else { return merged(["pick": true], host.look()) }
            return try await config(for: file)
        case kind.op("open"):
            return try await open(path(params["path"]))
        case kind.op("save"):
            return try await save(params)
        case kind.op("setPreference"):
            try await setPreference(params, host: host, userGesture: context.userGesture)
            return .object([:])
        case kind.op("recents"):
            return host.recents()
        case kind.op("chooseFile"):
            let start = params["start"]?.stringValue.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            guard let chosen = await host.chooseFile(start: start) else { return .null }
            granted.insert(Self.canonical(chosen).path)
            return ["path": .string(chosen.path)]
        case kind.op("openLink"):
            try await openLink(params, host: host, userGesture: context.userGesture)
            return .object([:])
        case kind.op("resolveLinks") where kind == .markdown:
            return try resolveLinks(params, host: host)
        case kind.op("listFiles") where kind == .markdown:
            return try listFiles(params)
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
            return PageSubscription { [weak self] in self?.changeListeners[id] = nil }
        case kind.op("look"):
            let stop = host.listenLook(onEvent)
            return PageSubscription { stop() }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    // MARK: Files

    private func path(_ value: JSONValue?) throws -> URL {
        guard let path = value?.stringValue, path.hasPrefix("/"), !path.contains("\u{0}") else {
            throw PageError.invalidParams("path must be absolute")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Writable: a document the user granted, or a file inside a folder the user chose as a root.
    private func inWorkspace(_ url: URL) -> Bool {
        let path = Self.canonical(url).path
        return granted.contains(path) || (host?.roots.contains(path) ?? false)
    }

    /// Links resolved, `.` and `..` removed: the path every grant check compares.
    nonisolated static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// Whether `url` (canonical) is inside the folder of a granted document.
    private func inGrantedFolder(_ url: URL) -> Bool {
        granted.contains { document in
            let folder = URL(fileURLWithPath: document).deletingLastPathComponent().path
            return url.path.hasPrefix(folder == "/" ? "/" : folder + "/")
        }
    }

    /// `open` takes only a granted path: the tab's document, a chooseFile result, an approved
    /// link, a recents entry, or a markdown file `resolveLinks` found in a granted folder.
    private func mayOpen(_ url: URL) -> Bool {
        let path = url.path
        return granted.contains(path) || shown.contains(path) || linked.contains(path) || (host?.isRecent(path) ?? false)
    }

    private func snapshot(_ url: URL) async throws -> FileSnapshot {
        do {
            return try await Self.read(url, inWorkspace: inWorkspace(url.resolvingSymlinksInPath()))
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
        if granted.contains(opened.url.path) || host?.isRecent(opened.url.path) == true { granted.insert(opened.url.path) }
        shown.insert(opened.url.path)
        if opened.url != file {
            file = opened.url
            assetToken = UUID().uuidString.lowercased()
            restartWatch(known: opened.hash)
        }
        host?.record(opened.url)
        host?.opened(opened.url)
        return config(opened)
    }

    private func config(for url: URL) async throws -> JSONValue {
        let file = try await snapshot(url)
        // A tab made with its file starts watching on its first config.
        if file.url == self.file, watch == nil { restartWatch(known: file.hash) }
        return config(file)
    }

    private func config(_ file: FileSnapshot) -> JSONValue {
        var config: [String: JSONValue] = ["path": .string(file.url.path), "text": .string(file.text), "hash": .string(file.hash)]
        if let reason = file.readOnlyReason {
            config["readOnly"] = true
            if kind == .editor { config["readOnlyReason"] = .string(reason.rawValue) }
        }
        switch kind {
        case .markdown:
            config["assetBase"] = .string("\(origin)/\(MarkdownPageResource.asset)/\(assetToken)/")
            config["libBase"] = .string("\(origin)/\(MarkdownPageResource.library)/")
            if host?.remoteImages ?? false { config["remoteImageBase"] = .string("\(origin)/\(MarkdownPageResource.remoteImage)/") }
        case .editor:
            config["size"] = JSONValue(file.size)
        }
        return merged(.object(config), host?.look() ?? .object([:]))
    }

    private func merged(_ base: JSONValue, _ look: JSONValue) -> JSONValue {
        var members = look.objectValue ?? [:]
        for (key, value) in base.objectValue ?? [:] { members[key] = value }
        return .object(members)
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
        let watch = FileChangeWatch(url: file, inWorkspace: { [weak self] in self?.inWorkspace(file) ?? false }, clock: clock) { [weak self] snapshot in
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

    /// Keys only the host (or the user in Settings) writes, never a page.
    nonisolated static let hostOnlyKeys: Set<String> = ["markdown.remoteImages", "files.roots"]

    nonisolated static func isPreferenceKey(_ key: String, section: String) -> Bool {
        guard !hostOnlyKeys.contains(key), !hostOnlyKeys.contains(where: { key.hasPrefix($0 + ".") }) else { return false }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 6, parts[0] == section, key.count <= 96 else { return false }
        return parts.dropFirst().allSatisfy { part in
            guard let first = part.first, first.isLetter, first.isASCII else { return false }
            return part.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
        }
    }

    // MARK: Links

    private func openLink(_ params: JSONValue, host: any FilePageHosting, userGesture: Bool) async throws {
        guard let href = params["href"]?.stringValue else { throw PageError.invalidParams("href is required") }
        if kind == .markdown, params["kind"]?.stringValue == "file" {
            let target = Self.canonical(try path(params["target"]))
            guard FileManager.default.fileExists(atPath: target.path) else { throw PageError(code: kind.op("not_found"), message: target.path) }
            // Inside a granted document's folder (links resolved): opens. Anything else asks,
            // naming the resolved path; a refused or unshown sheet refuses the link.
            if !inGrantedFolder(target) {
                guard await host.confirmOpen(target, userGesture: userGesture) else { throw PageError.cancelled }
                granted.insert(target.path)
            }
            return host.openFile(target)
        }
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else {
            throw PageError.invalidParams("links open only http(s), mailto: and tel:")
        }
        host.openExternal(url)
    }

    /// The real path of a relative link target of the tab's file, inside its folder or a workspace root.
    private func target(_ relative: String, from base: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\u{0}") else { return nil }
        let real = base.deletingLastPathComponent().appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let folder = base.deletingLastPathComponent().path
        guard real.path.hasPrefix(folder + "/") || host?.roots.contains(real.path) == true else { return nil }
        return real
    }

    private func linkBase(_ params: JSONValue) throws -> URL {
        let from = try path(params["from"])
        guard let file, from.resolvingSymlinksInPath() == file else { throw PageError.invalidParams("from is not this page's file") }
        return file
    }

    private func resolveLinks(_ params: JSONValue, host: any FilePageHosting) throws -> JSONValue {
        let base = try linkBase(params)
        var links: [String: JSONValue] = [:]
        for case .string(let relative) in (params["paths"]?.arrayValue ?? []).prefix(500) {
            guard let real = target(relative, from: base) else {
                links[relative] = ["exists": false]
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory) else {
                links[relative] = ["exists": false, "path": .string(real.path)]
                continue
            }
            let kind = isDirectory.boolValue ? "directory" : FilePageKind.isMarkdown(real) ? "markdown" : "file"
            if kind == "markdown", inGrantedFolder(real) { linked.insert(real.path) }
            links[relative] = ["exists": true, "path": .string(real.path), "kind": .string(kind)]
        }
        return ["links": .object(links)]
    }

    private func listFiles(_ params: JSONValue) throws -> JSONValue {
        let base = try linkBase(params)
        let prefix = params["prefix"]?.stringValue ?? ""
        guard !prefix.hasPrefix("/"), !prefix.split(separator: "/").contains("..") else { return ["entries": []] }
        let folderPart = prefix.lastIndex(of: "/").map { String(prefix[...$0]) } ?? ""
        let start = String(prefix.dropFirst(folderPart.count)).lowercased()
        // Symlinks resolved before the folder check: a link in the folder may point anywhere.
        let root = Self.canonical(base.deletingLastPathComponent())
        let directory = folderPart.isEmpty ? root : Self.canonical(root.appending(path: folderPart, directoryHint: .isDirectory))
        guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return ["entries": []] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let entries = names
            .filter { !$0.hasPrefix(".") && $0 != "node_modules" && $0.lowercased().hasPrefix(start) }
            .map { name -> (String, Bool) in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory)
                return (name, isDirectory.boolValue)
            }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .prefix(Self.listLimit)
            .map { JSONValue.string(folderPart + $0.0 + ($0.1 ? "/" : "")) }
        return ["entries": .array(Array(entries))]
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
