@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// One file page tab's `cmux.markdown.*` and `cmux.editor.*` ops (diff-host S6 "Markdown page
/// contract", S7 "Editor page"), against a fake host.
@MainActor
@Suite(.serialized)
struct FilePageProviderTests {
    final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots
        var recorded: [URL] = []
        var opened: [URL] = []
        var external: [URL] = []
        var files: [URL] = []
        var chosen: URL?
        var preferences: [(String, JSONValue)] = []
        var writers: [SettingWriter] = []
        var confirmGestures: [Bool] = []
        var edits: [(text: String, baseHash: String?)] = []
        var savedHashes: [String] = []
        var lookValue: JSONValue = ["settings": ["toolbar": true], "themeCSS": ""]
        var lookListeners: [UUID: (JSONValue) -> Void] = [:]
        var remoteImages = true
        var recentPaths: [String] = []
        var confirmations: [URL] = []
        var confirmAnswer = false

        init(roots: FileWorkspaceRoots) { self.roots = roots }

        func recents() -> JSONValue { ["home": "/Users/ada", "items": .array(recorded.map { ["path": .string($0.path), "openedAt": 1] })] }
        func record(_ url: URL) { recorded.append(url) }
        func chooseFile(start: URL?) async -> URL? { chosen }
        func look() -> JSONValue { lookValue }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void {
            let id = UUID()
            lookListeners[id] = onLook
            return { [weak self] in self?.lookListeners[id] = nil }
        }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {
            preferences.append((key, value))
            writers.append(writer)
        }
        func opened(_ url: URL) { opened.append(url) }
        func openExternal(_ url: URL) { external.append(url) }
        func openFile(_ url: URL) { files.append(url) }
        func isRecent(_ path: String) -> Bool { recentPaths.contains(path) }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance {
            edits.append((text, baseHash))
            return .kept
        }
        func saved(_ url: URL, hash: String) { savedHashes.append(hash) }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool {
            confirmations.append(url)
            confirmGestures.append(userGesture)
            return confirmAnswer
        }
    }

    final class Images: RemoteImageFetching {
        var asked: [URL] = []
        func fetch(_ url: URL) async -> PageResource? {
            asked.append(url)
            return PageResource(data: Data([1, 2, 3]), mimeType: "image/png")
        }
    }

    static func world(_ kind: FilePageKind, file name: String? = "README.md", text: String = "# Title\n\n![x](img/a.png)\n")
        throws -> (FilePageProvider, Host, URL, Images) {
        let folder = try FileDocumentTests.folder()
        try FileDocumentTests.makeDirectory(folder.appending(path: ".git"))
        try FileDocumentTests.makeDirectory(folder.appending(path: "img"))
        try Data([0x89, 0x50]).write(to: folder.appending(path: "img/a.png"))
        try Data("secret".utf8).write(to: folder.appending(path: "img/notes.txt"))
        try Data("# Other\n".utf8).write(to: folder.appending(path: "other.md"))
        try Data("let x = 1\n".utf8).write(to: folder.appending(path: "main.swift"))
        let file = name.map { folder.appending(path: $0) }
        if let file { try Data(text.utf8).write(to: file) }
        let host = Host(roots: FileWorkspaceRoots(folders: [folder.path], home: "/nonexistent-home"))
        let images = Images()
        let libraries = folder.appending(path: "libs", directoryHint: .isDirectory)
        try FileDocumentTests.makeDirectory(libraries)
        for (name, text) in [("mermaid.min.js", "M"), ("vega.min.js", "V"), ("vega-lite.min.js", "L")] {
            try Data(text.utf8).write(to: libraries.appending(path: name))
        }
        let provider = FilePageProvider(kind: kind, file: file, host: host, clock: ManualClock(), libraries: libraries, images: images)
        return (provider, host, folder, images)
    }

    static func call(_ provider: FilePageProvider, _ op: String, _ params: JSONValue = .object([:]),
                     userGesture: Bool = false) async throws -> JSONValue {
        try await provider.call(op, params: params, context: PageCallContext(page: provider.kind.descriptor.id, userGesture: userGesture))
    }

    static func code(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as PageError {
            return error.code
        } catch {
            return "\(error)"
        }
    }

    @Test func aTabWithNoFileAnswersPickWithItsLook() async throws {
        let (provider, _, _, _) = try Self.world(.editor, file: nil)
        let config = try await Self.call(provider, "cmux.editor.config")
        #expect(config["pick"]?.boolValue == true)
        #expect(config["settings"]?["toolbar"]?.boolValue == true)
        #expect(provider.isPicking)
    }

    @Test func theMarkdownConfigCarriesTheFileItsBasesAndTheLook() async throws {
        let (provider, _, folder, _) = try Self.world(.markdown)
        let config = try await Self.call(provider, "cmux.markdown.config")
        #expect(config["path"]?.stringValue == folder.appending(path: "README.md").path)
        #expect(config["text"]?.stringValue == "# Title\n\n![x](img/a.png)\n")
        #expect(config["hash"]?.stringValue == FileDocument.hash(Data("# Title\n\n![x](img/a.png)\n".utf8)))
        #expect(config["readOnly"]?.boolValue != true)
        let assetBase = try #require(config["assetBase"]?.stringValue)
        #expect(assetBase.hasPrefix("cmux-page://cmux.markdown/__asset/") && assetBase.hasSuffix("/"))
        #expect(config["libBase"]?.stringValue == "cmux-page://cmux.markdown/__lib/")
        #expect(config["remoteImageBase"]?.stringValue == "cmux-page://cmux.markdown/__image/")
        #expect(config["settings"]?["toolbar"]?.boolValue == true)
    }

    @Test func theEditorConfigSaysWhyAFileIsReadOnly() async throws {
        let (provider, host, folder, images) = try Self.world(.editor, file: "main.swift", text: "let x = 1\n")
        var config = try await Self.call(provider, "cmux.editor.config")
        #expect(config["size"]?.intValue == 10)
        #expect(config["readOnly"]?.boolValue != true)
        // A document an agent opened is writable only inside a root the user chose.
        host.roots = FileWorkspaceRoots(folders: [], home: "/nonexistent-home")
        let agentOpened = FilePageProvider(kind: .editor, file: folder.appending(path: "main.swift"), userChose: false, host: host,
                                           clock: ManualClock(), libraries: nil, images: images)
        config = try await Self.call(agentOpened, "cmux.editor.config")
        #expect(config["readOnly"]?.boolValue == true)
        #expect(config["readOnlyReason"]?.stringValue == "outside")
    }

    @Test func openSwitchesTheTabsFileRecordsItAndRefusesWhatItCannotShow() async throws {
        let (provider, host, folder, _) = try Self.world(.markdown)
        let other = folder.appending(path: "other.md")
        host.chosen = other
        _ = try await Self.call(provider, "cmux.markdown.chooseFile")
        let config = try await Self.call(provider, "cmux.markdown.open", ["path": .string(other.path)])
        #expect(config["text"]?.stringValue == "# Other\n")
        #expect(provider.file == other)
        #expect(host.recorded.last == other && host.opened.last == other)
        #expect(await Self.code { _ = try await Self.call(provider, "cmux.markdown.open", ["path": .string(folder.appending(path: "main.swift").path)]) }
            == "cmux.markdown.forbidden")
        host.chosen = folder.appending(path: "main.swift")
        _ = try await Self.call(provider, "cmux.markdown.chooseFile")
        #expect(await Self.code { _ = try await Self.call(provider, "cmux.markdown.open", ["path": .string(folder.appending(path: "main.swift").path)]) }
            == "cmux.markdown.not_markdown")
        host.chosen = folder.appending(path: "gone.md")
        _ = try await Self.call(provider, "cmux.markdown.chooseFile")
        #expect(await Self.code { _ = try await Self.call(provider, "cmux.markdown.open", ["path": .string(folder.appending(path: "gone.md").path)]) }
            == "cmux.markdown.not_found")
        let (editor, editorHost, _, _) = try Self.world(.editor, file: nil)
        editorHost.chosen = folder
        _ = try await Self.call(editor, "cmux.editor.chooseFile")
        #expect(await Self.code { _ = try await Self.call(editor, "cmux.editor.open", ["path": .string(folder.path)]) } == "cmux.editor.not_file")
        #expect(await Self.code { _ = try await Self.call(editor, "cmux.editor.open", ["path": "relative.txt"]) } == "cmux.protocol.invalid_params")
    }

    @Test func aSaveWritesTheBytesAndAStaleBaseIsTheConflictTheBannerShows() async throws {
        let (provider, _, folder, _) = try Self.world(.editor, file: "main.swift", text: "let x = 1\n")
        let file = folder.appending(path: "main.swift")
        let base = FileDocument.hash(Data("let x = 1\n".utf8))
        let saved = try await Self.call(provider, "cmux.editor.save", ["path": .string(file.path), "text": "let x = 2\n", "baseHash": .string(base)])
        #expect(saved["hash"]?.stringValue == FileDocument.hash(Data("let x = 2\n".utf8)))
        #expect(try String(contentsOf: file, encoding: .utf8) == "let x = 2\n")
        try Data("let x = 3\n".utf8).write(to: file)
        do {
            _ = try await Self.call(provider, "cmux.editor.save", ["path": .string(file.path), "text": "let x = 4\n",
                                                                   "baseHash": .string(FileDocument.hash(Data("let x = 2\n".utf8)))])
            Issue.record("a stale save was written")
        } catch let error as PageError {
            #expect(error.code == "cmux.editor.conflict")
            #expect(error.details?["text"]?.stringValue == "let x = 3\n")
            #expect(error.details?["hash"]?.stringValue == FileDocument.hash(Data("let x = 3\n".utf8)))
        }
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await Self.call(provider, "cmux.editor.save", ["path": .string(file.path), "text": "x", "baseHash": .string(base)])
            Issue.record("a save over a deleted file was written")
        } catch let error as PageError {
            #expect(error.code == "cmux.editor.conflict")
            #expect(error.details?["deleted"]?.boolValue == true)
        }
        // Only the tab's own file is saved.
        #expect(await Self.code {
            _ = try await Self.call(provider, "cmux.editor.save", ["path": .string(folder.appending(path: "other.md").path), "text": "x", "baseHash": .null])
        } == "cmux.protocol.invalid_params")
    }

    @Test func aReadOnlyFileRefusesItsSave() async throws {
        let (_, host, folder, images) = try Self.world(.markdown)
        host.roots = FileWorkspaceRoots(folders: [], home: "/nonexistent-home")
        let file = folder.appending(path: "README.md")
        let provider = FilePageProvider(kind: .markdown, file: file, userChose: false, host: host, clock: ManualClock(),
                                        libraries: nil, images: images)
        let config = try await Self.call(provider, "cmux.markdown.open", ["path": .string(file.path)])
        #expect(config["readOnly"]?.boolValue == true)
        #expect(await Self.code {
            _ = try await Self.call(provider, "cmux.markdown.save", ["path": .string(file.path), "text": "x", "baseHash": config["hash"] ?? .null])
        } == "cmux.markdown.read_only")
    }

    /// PAGE-PREFS: a toolbar toggle is one settings key in the page's own section, never web storage.
    /// The writer is the user only for a call backed by a real gesture, else the page; host-only
    /// keys (`files.roots`, `markdown.remoteImages`) are never the page's to write.
    @Test func setPreferenceWritesOnlyItsOwnSectionsKeysAsItsWriter() async throws {
        let (provider, host, _, _) = try Self.world(.editor, file: nil)
        _ = try await Self.call(provider, "cmux.editor.setPreference", ["key": "editor.minimap.enabled", "value": true])
        _ = try await Self.call(provider, "cmux.editor.setPreference", ["key": "editor.wordWrap", "value": "on"], userGesture: true)
        #expect(host.preferences.map(\.0) == ["editor.minimap.enabled", "editor.wordWrap"])
        #expect(host.writers == [.caller("page"), .user])
        for key in ["markdown.font.size", "editor", "editor..x", "appearance.surfaces.editor.color", "editor.__proto__x!", "files.roots"] {
            #expect(await Self.code { _ = try await Self.call(provider, "cmux.editor.setPreference", ["key": .string(key), "value": 1]) }
                == "cmux.protocol.invalid_params", "\(key)")
        }
        let (markdown, markdownHost, _, _) = try Self.world(.markdown)
        for key in ["markdown.remoteImages", "files.roots", "editor.wordWrap"] {
            #expect(await Self.code { _ = try await Self.call(markdown, "cmux.markdown.setPreference", ["key": .string(key), "value": true]) }
                == "cmux.protocol.invalid_params", "\(key)")
            #expect(!FilePageProvider.isPreferenceKey(key, section: "markdown"), "\(key)")
        }
        #expect(markdownHost.preferences.isEmpty)
        #expect(host.preferences.count == 2)
    }

    /// The page path writes settings only through `SettingsController.setSetting(at:to:by:)`: a key
    /// the schema does not list is refused and the file is not touched (no raw file write).
    @Test func thePageLookWritesOnlyThroughTheSettingsSchema() async throws {
        let folder = try FileDocumentTests.folder()
        let url = folder.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        await settings.reload()
        let look = FilePageLook(kind: .editor, settings: { settings }, configDirectory: folder)
        await #expect(throws: SettingNotInSchema.self) {
            try await look.setPreference(key: "editor.someKeyNotInTheSchema", value: true, by: .user)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
    }

    @Test func linksResolveInsideTheRootsAndListFilesCompletesTheFilesFolder() async throws {
        let (provider, _, folder, _) = try Self.world(.markdown)
        let from = folder.appending(path: "README.md").path
        let resolved = try await Self.call(provider, "cmux.markdown.resolveLinks",
                                           ["from": .string(from), "paths": ["other.md", "main.swift", "img", "missing.md", "../../etc/passwd"]])
        let links = try #require(resolved["links"])
        #expect(links["other.md"]?["kind"]?.stringValue == "markdown")
        #expect(links["main.swift"]?["kind"]?.stringValue == "file")
        #expect(links["img"]?["kind"]?.stringValue == "directory")
        #expect(links["missing.md"]?["exists"]?.boolValue == false)
        #expect(links["../../etc/passwd"]?["exists"]?.boolValue == false)
        let listed = try await Self.call(provider, "cmux.markdown.listFiles", ["from": .string(from), "prefix": "im"])
        #expect(listed["entries"]?.arrayValue?.compactMap(\.stringValue) == ["img/"])
        let inside = try await Self.call(provider, "cmux.markdown.listFiles", ["from": .string(from), "prefix": "img/"])
        #expect(inside["entries"]?.arrayValue?.compactMap(\.stringValue) == ["img/a.png", "img/notes.txt"])
        let escape = try await Self.call(provider, "cmux.markdown.listFiles", ["from": .string(from), "prefix": "../"])
        #expect(escape["entries"]?.arrayValue?.isEmpty == true)
    }

    @Test func followedLinksOpenWhereTheirKindSays() async throws {
        let (provider, host, folder, _) = try Self.world(.markdown)
        let from = folder.appending(path: "README.md").path
        _ = try await Self.call(provider, "cmux.markdown.openLink", ["path": .string(from), "href": "https://example.com/a", "kind": "external"])
        _ = try await Self.call(provider, "cmux.markdown.openLink", ["path": .string(from), "href": "mailto:a@b.c", "kind": "mail"])
        _ = try await Self.call(provider, "cmux.markdown.openLink", ["path": .string(from), "href": "main.swift", "kind": "file",
                                                                     "target": .string(folder.appending(path: "main.swift").path)])
        #expect(host.external.map(\.absoluteString) == ["https://example.com/a", "mailto:a@b.c"])
        #expect(host.files == [folder.appending(path: "main.swift")])
        #expect(await Self.code {
            _ = try await Self.call(provider, "cmux.markdown.openLink", ["path": .string(from), "href": "javascript:alert(1)", "kind": "external"])
        } == "cmux.protocol.invalid_params")
        #expect(host.external.count == 2)
    }

    /// Images come only from the file's folder, under the token of its current open.
    @Test func localImagesComeOnlyFromTheFilesFolder() async throws {
        let (provider, _, _, _) = try Self.world(.markdown)
        let config = try await Self.call(provider, "cmux.markdown.config")
        let base = try #require(config["assetBase"]?.stringValue)
        let token = String(base.dropFirst("cmux-page://cmux.markdown/__asset/".count).dropLast())
        func get(_ path: [String]) async -> PageResource? {
            await provider.resource(for: PageResourceRequest(prefix: "__asset", path: path, url: URL(fileURLWithPath: "/")))
        }
        #expect(await get([token, "img", "a.png"])?.mimeType == "image/png")
        #expect(await get([token, "img", "notes.txt"]) == nil, "only image types")
        #expect(await get(["wrong", "img", "a.png"]) == nil)
        let lib = await provider.resource(for: PageResourceRequest(prefix: "__lib", path: ["vega.js"], url: URL(fileURLWithPath: "/")))
        #expect(lib.map { String(decoding: $0.data, as: UTF8.self) } == "V\n;\nL")
        #expect(await provider.resource(for: PageResourceRequest(prefix: "__lib", path: ["other.js"], url: URL(fileURLWithPath: "/"))) == nil)
    }

    /// markdown.remoteImages (default true): the host fetches the image, the page CSP stays strict.
    @Test func remoteImagesGoThroughTheHostOnlyWhenTheSettingAllowsThem() async throws {
        let (provider, host, _, images) = try Self.world(.markdown)
        let encoded = RemoteImagePolicy.encode(try #require(URL(string: "https://example.com/a.png")))
        let request = PageResourceRequest(prefix: "__image", path: [encoded], url: URL(fileURLWithPath: "/"))
        #expect(await provider.resource(for: request)?.data == Data([1, 2, 3]))
        #expect(images.asked.map(\.absoluteString) == ["https://example.com/a.png"])
        host.remoteImages = false
        #expect(await provider.resource(for: request) == nil)
        #expect(try await Self.call(provider, "cmux.markdown.config")["remoteImageBase"] == nil)
        host.remoteImages = true
        let local = PageResourceRequest(prefix: "__image", path: [RemoteImagePolicy.encode(try #require(URL(string: "http://127.0.0.1:8080/x.png")))],
                                        url: URL(fileURLWithPath: "/"))
        #expect(await provider.resource(for: local) == nil)
        #expect(images.asked.count == 1)
    }

    @Test func theRemoteImagePolicyRefusesLocalHostsAndNonImages() throws {
        for allowed in ["https://example.com/a.png", "https://cdn.example.org/x"] {
            #expect(RemoteImagePolicy.allows(try #require(URL(string: allowed))), "\(allowed)")
        }
        for refused in ["http://localhost/a.png", "http://127.0.0.1/a", "http://10.0.0.2/a", "http://192.168.1.4/a",
                        "http://172.16.0.1/a", "http://169.254.169.254/latest", "http://[::1]/a", "http://0.0.0.0/a",
                        "file:///etc/passwd", "data:image/png;base64,AA", "ftp://example.com/a", "http://foo.local/a",
                        "http://example.com/a.png", "https://user:pass@example.com/a.png"] {
            #expect(!RemoteImagePolicy.allows(try #require(URL(string: refused))), "\(refused)")
        }
        #expect(RemoteImagePolicy.imageType("image/png; charset=binary") == "image/png")
        #expect(RemoteImagePolicy.imageType("image/svg+xml") == "image/svg+xml")
        #expect(RemoteImagePolicy.imageType("text/html") == nil)
        #expect(RemoteImagePolicy.imageType(nil) == nil)
        let url = try #require(URL(string: "https://example.com/a b.png?x=1&y=ü"))
        #expect(RemoteImagePolicy.decode(RemoteImagePolicy.encode(url)) == url)
        #expect(!RemoteImagePolicy.encode(url).contains("/"))
        #expect(RemoteImagePolicy.maximumBytes == 10 * 1024 * 1024)
    }

    @Test func theLookStreamForwardsTheHostsLookAndStopsWithTheSubscription() async throws {
        let (provider, host, _, _) = try Self.world(.editor, file: nil)
        var events: [JSONValue] = []
        let subscription = try await provider.subscribe("cmux.editor.look", filter: .object([:]),
                                                        context: PageCallContext(page: "cmux.editor")) { events.append($0) }
        for listener in host.lookListeners.values { listener(["settings": ["wordWrap": "on"]]) }
        #expect(events == [["settings": ["wordWrap": "on"]]])
        subscription.cancel()
        #expect(host.lookListeners.isEmpty)
    }
}
