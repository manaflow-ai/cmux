import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium browser engine")
struct ChromiumEngineTests {
    @Test("Unset preference follows the system default browser")
    func engineDefaults() {
        #expect(BrowserEngineKind(persistedRawValue: "unknown") == .webkit)
        #expect(BrowserEngineKind(persistedRawValue: "CHROME") == .chromium)
        let defaults = UserDefaults(suiteName: "ChromiumEngineTests.engineDefaults")!
        defaults.removePersistentDomain(forName: "ChromiumEngineTests.engineDefaults")
        let store = BrowserEngineSettingsStore(defaults: defaults)
        #expect(store.defaultEngineChoice() == .auto)
        #expect(store.defaultEngineValue(systemDefaultBrowserIsChromium: false) == .webkit)
        #expect(store.defaultEngineValue(systemDefaultBrowserIsChromium: true) == .chromium)
        store.setDefaultEngine(.chromium)
        #expect(store.defaultEngineValue(systemDefaultBrowserIsChromium: false) == .chromium)
        store.setDefaultEngine(.webkit)
        #expect(store.defaultEngineValue(systemDefaultBrowserIsChromium: true) == .webkit)
    }

    @Test("Legacy engine preference is migrated into the current key")
    func legacyEnginePreferenceMigrates() {
        let suiteName = "ChromiumEngineTests.legacyEngine"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("chromium", forKey: "browser.engine")

        let store = BrowserEngineSettingsStore(defaults: defaults)
        #expect(store.defaultEngineValue(systemDefaultBrowserIsChromium: false) == .chromium)
        #expect(defaults.string(forKey: BrowserEngineSettingsStore.defaultEngineKey) == "chromium")
    }

    @Test("Extension directories are validated and passed to Chromium exactly")
    func extensionDirectoryArguments() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-extension-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid-extension", isDirectory: true)
        try fileManager.createDirectory(at: valid, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: valid.appendingPathComponent("manifest.json"))
        let missingManifest = root.appendingPathComponent("no-manifest", isDirectory: true)
        try fileManager.createDirectory(at: missingManifest, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "ChromiumEngineTests.extensionDirs")!
        defaults.removePersistentDomain(forName: "ChromiumEngineTests.extensionDirs")
        defaults.set(
            [
                valid.path,
                missingManifest.path,
                root.appendingPathComponent("does-not-exist").path,
                "relative/path",
                "# comment",
                valid.path,
            ].joined(separator: "\n"),
            forKey: BrowserEngineSettingsStore.chromiumExtensionDirectoriesKey
        )
        let store = BrowserEngineSettingsStore(defaults: defaults)
        let directories = store.chromiumExtensionDirectories(fileManager: fileManager)
        #expect(directories.map(\.lastPathComponent) == ["valid-extension"])

        let configuration = ChromiumLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/chrome"),
            profileDirectory: URL(fileURLWithPath: "/tmp/cmux-profile"),
            debuggingTransport: .pipe,
            extensionDirectories: directories
        )
        let arguments = ChromiumLaunchArguments(configuration: configuration).values
        let expectedPath = valid.standardizedFileURL.path
        #expect(arguments.contains("--load-extension=\(expectedPath)"))
        #expect(arguments.contains("--disable-extensions-except=\(expectedPath)"))
    }

    @Test("No configured extensions adds no extension flags")
    func noExtensionArgumentsByDefault() {
        let configuration = ChromiumLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/chrome"),
            profileDirectory: URL(fileURLWithPath: "/tmp/cmux-profile"),
            debuggingTransport: .pipe
        )
        let arguments = ChromiumLaunchArguments(configuration: configuration).values
        #expect(!arguments.contains(where: { $0.hasPrefix("--load-extension") }))
        #expect(!arguments.contains(where: { $0.hasPrefix("--disable-extensions-except") }))
    }

    @Test("Unknown persisted engine values decode as WebKit")
    func engineSnapshotDecodingFailsClosed() throws {
        let data = Data("\"future-engine\"".utf8)
        #expect(try JSONDecoder().decode(BrowserEngineKind.self, from: data) == .webkit)
        let encoded = try JSONEncoder().encode(BrowserEngineKind.chromium)
        #expect(String(data: encoded, encoding: .utf8) == "\"chromium\"")
    }

    @Test("CDP errors use product messages instead of raw transport details")
    func cdpErrorsRedactRawMessages() {
        let raw = "file:///Users/example/secret-profile: renderer rejected command"
        #expect(!CDPError.disconnected(raw).description.contains(raw))
        #expect(!CDPError.protocolError(raw).description.contains(raw))
        #expect(!CDPError.commandFailed(raw).description.contains(raw))
    }

    @Test("Launch arguments keep profile and CDP loopback-only")
    func launchArguments() {
        let configuration = ChromiumLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/chrome-headless-shell"),
            profileDirectory: URL(fileURLWithPath: "/tmp/cmux-profile"),
            debuggingTransport: .loopback(port: 9222),
            additionalArguments: [
                "--remote-debugging-address=0.0.0.0",
                "--remote-debugging-port=80",
                "--user-data-dir=/Users/other/Library/Application Support/Google/Chrome",
                "--remote-debugging-address", "0.0.0.0",
                "--remote-debugging-port", "80",
                "--remote-debugging-pipe",
                "--remote-allow-origins=*",
                "--user-data-dir", "/Users/other/Library/Application Support/Google/Chrome",
                "-remote-debugging-port=9223",
                "-user-data-dir=/Users/other/Library/Application Support/Google/Chrome",
                "-remote-debugging-pipe",
                "--disable-gpu",
            ]
        )
        let arguments = ChromiumLaunchArguments(configuration: configuration).values
        #expect(arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(arguments.contains("--remote-debugging-port=9222"))
        #expect(arguments.contains(
            "--remote-allow-origins=http://127.0.0.1:9222,http://localhost:9222,devtools://devtools"
        ))
        #expect(arguments.contains("--user-data-dir=/tmp/cmux-profile"))
        #expect(arguments.contains("--disable-gpu"))
        #expect(!arguments.contains(where: { $0.contains("0.0.0.0") }))
        #expect(!arguments.contains(where: { $0.contains("Google/Chrome") }))
        #expect(!arguments.contains("--remote-debugging-address"))
        #expect(!arguments.contains("--remote-debugging-port"))
        #expect(!arguments.contains("--user-data-dir"))
        #expect(arguments.filter { $0.hasPrefix("--remote-allow-origins=") } == [
            "--remote-allow-origins=http://127.0.0.1:9222,http://localhost:9222,devtools://devtools",
        ])
    }

    @Test("Disabled remote debugging uses a private pipe and no listener")
    func privatePipeLaunchArguments() {
        let configuration = ChromiumLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/chrome-headless-shell"),
            profileDirectory: URL(fileURLWithPath: "/tmp/cmux-profile"),
            debuggingTransport: .pipe,
            additionalArguments: [
                "--remote-debugging-address=0.0.0.0",
                "--remote-debugging-port=9222",
                "--remote-allow-origins=*",
                "--disable-gpu",
            ]
        )
        let arguments = ChromiumLaunchArguments(configuration: configuration).values
        #expect(arguments.contains("--remote-debugging-pipe"))
        #expect(arguments.contains("--disable-gpu"))
        #expect(!arguments.contains(where: { $0.hasPrefix("--remote-debugging-address") }))
        #expect(!arguments.contains(where: { $0.hasPrefix("--remote-debugging-port") }))
        #expect(!arguments.contains(where: { $0.hasPrefix("--remote-allow-origins") }))
    }

    @Test("Private pipe launcher maps and frames Chromium CDP descriptors")
    func privatePipeDescriptorMapping() async throws {
        let launch = try ChromiumCDPPipeLaunch()
        let process = Process()
        launch.configure(
            process,
            chromiumExecutable: URL(fileURLWithPath: "/bin/sh"),
            chromiumArguments: [
                "-c",
                "dd bs=1 count=3 <&3 >/dev/null 2>/dev/null; " +
                    "printf '{\"id\":1,\"result\":{}}\\0' >&4",
            ]
        )
        process.standardError = FileHandle.nullDevice
        try process.run()
        launch.closeFoundationHandles()

        let messages = launch.transport.messages()
        let responseTask = Task<Result<Data, CDPError>?, Never> {
            for await message in messages {
                return message
            }
            return nil
        }
        await launch.transport.connect()
        try await launch.transport.send(Data("{}".utf8))
        let optionalResponse = await responseTask.value
        let responseResult = try #require(optionalResponse)
        let response = try responseResult.get()
        process.waitUntilExit()
        await launch.transport.close()

        #expect(process.terminationStatus == 0)
        #expect(String(decoding: response, as: UTF8.self) == "{\"id\":1,\"result\":{}}")
    }

    @Test("CDP discovery rejects redirects and non-loopback websocket metadata")
    func cdpEndpointValidation() throws {
        let validResponse = try #require(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9222/json/list")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        try ChromiumCDPEndpointDiscovery.validate(
            validResponse,
            requestedURL: URL(string: "http://127.0.0.1:9222/json/list")!,
            port: 9222
        )

        let redirectedResponse = try #require(HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:9222/json/list")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        #expect(throws: CDPError.self) {
            try ChromiumCDPEndpointDiscovery.validate(
                redirectedResponse,
                requestedURL: URL(string: "http://127.0.0.1:9222/json/list")!,
                port: 9223
            )
        }
        #expect(throws: CDPError.self) {
            try ChromiumCDPEndpointDiscovery.validateWebSocket(
                URL(string: "ws://192.168.1.5:9222/devtools/page/1")!,
                port: 9222,
                kind: .page
            )
        }
        #expect(throws: CDPError.self) {
            try ChromiumCDPEndpointDiscovery.validateWebSocket(
                URL(string: "wss://127.0.0.1:9222/devtools/page/1")!,
                port: 9222,
                kind: .page
            )
        }
        try ChromiumCDPEndpointDiscovery.validateWebSocket(
            URL(string: "ws://127.0.0.1:9222/devtools/page/target-id")!,
            port: 9222,
            kind: .page
        )
        try ChromiumCDPEndpointDiscovery.validateWebSocket(
            URL(string: "ws://127.0.0.1:9222/devtools/browser/browser-id")!,
            port: 9222,
            kind: .browser
        )

        for invalidURL in [
            "ws://127.0.0.1:9222/",
            "ws://127.0.0.1:9222/devtools/page/",
            "ws://127.0.0.1:9222/devtools/page/target-id/extra",
            "ws://127.0.0.1:9222/devtools/browser/browser-id",
            "ws://127.0.0.1:9222/devtools/page/target-id?token=unexpected",
        ] {
            #expect(throws: CDPError.self) {
                try ChromiumCDPEndpointDiscovery.validateWebSocket(
                    URL(string: invalidURL)!,
                    port: 9222,
                    kind: .page
                )
            }
        }
    }

    @Test("Navigation matching includes URL ports and fragments")
    func navigationMatchingIncludesPortAndFragment() throws {
        let target = try #require(URL(string: "https://example.com:8443/path?q=1#section"))
        #expect(ChromiumBrowserSession.matches(
            url: URL(string: "https://EXAMPLE.com:8443/path?q=1#section"),
            target: target
        ))
        #expect(!ChromiumBrowserSession.matches(
            url: URL(string: "https://example.com:9443/path?q=1#section"),
            target: target
        ))
        #expect(!ChromiumBrowserSession.matches(
            url: URL(string: "https://example.com:8443/path?q=1#other"),
            target: target
        ))
        #expect(ChromiumBrowserSession.matches(
            url: URL(string: "https://example.com/path?q=1#section"),
            target: URL(string: "https://example.com:443/path?q=1#section")!
        ))
    }

    @Test("Chromium readiness accepts only a loopback DevTools websocket")
    func chromiumProcessReadinessParsing() {
        #expect(ChromiumProcessDiagnostics.port(
            from: "DevTools listening on ws://127.0.0.1:9222/devtools/browser/id"
        ) == 9222)
        #expect(ChromiumProcessDiagnostics.port(
            from: "DevTools listening on ws://0.0.0.0:9222/devtools/browser/id"
        ) == nil)
        #expect(ChromiumProcessDiagnostics.port(from: "ordinary Chromium diagnostic") == nil)
    }

    @Test("Remote debugging is disabled at zero and rejects invalid ports")
    func remoteDebuggingValidation() {
        #expect(ChromiumRemoteDebuggingPort(rawValue: -1) == nil)
        #expect(ChromiumRemoteDebuggingPort(rawValue: 1) == nil)
        #expect(ChromiumRemoteDebuggingPort(rawValue: 1023) == nil)
        #expect(ChromiumRemoteDebuggingPort(rawValue: 1024)?.rawValue == 1024)
        #expect(ChromiumRemoteDebuggingPort(rawValue: 65_536) == nil)
        #expect(ChromiumRemoteDebuggingPort.parse(" 9222 ")?.rawValue == 9222)
        #expect(ChromiumRemoteDebuggingPort.parse("not-a-port") == nil)
        #expect(!ChromiumRemoteDebuggingPort.disabled.isExternallyAttachable)
        #expect(BrowserCDPEndpoint(port: 0).connectOverCDPURL == nil)
        #expect(BrowserCDPEndpoint(port: 9222).connectOverCDPURL?.host == "127.0.0.1")
    }

    @Test("Loopback allocator resumes with an ephemeral port")
    func loopbackPortAllocation() async throws {
        let port = try await ChromiumLoopbackPortAllocator().allocate()
        #expect((1024...65_535).contains(port))
    }

    @Test("Profile paths are cmux-owned and pane-specific")
    func profileDirectoryIsolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-profile-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ChromiumOwnedStorage(
            fileManager: .default,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux/test" }
        )
        let first = try storage.profileDirectory(for: UUID())
        let second = try storage.profileDirectory(for: UUID())
        #expect(first.path.contains("ChromiumProfiles"))
        #expect(first != second)
        #expect(!first.path.contains("Google/Chrome"))
        #expect(first.path.contains("com.example.cmux_test"))

        let logicalProfileID = UUID()
        let firstPane = try storage.profileDirectory(for: logicalProfileID, storageID: UUID())
        let secondPane = try storage.profileDirectory(for: logicalProfileID, storageID: UUID())
        #expect(firstPane != secondPane)
        #expect(firstPane.path.contains("ChromiumProfiles/\(logicalProfileID.uuidString.lowercased())/Panes/"))
        #expect(secondPane.deletingLastPathComponent().deletingLastPathComponent() ==
            firstPane.deletingLastPathComponent().deletingLastPathComponent())
    }

    @Test("Profile cleanup removes every pane-owned Chromium directory")
    func profileDataCleanup() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-chromium-profile-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let profileID = UUID()
        let storage = ChromiumOwnedStorage(
            fileManager: fileManager,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux" }
        )
        let paneDirectory = try storage.profileDirectory(for: profileID, storageID: UUID())
        let environment = ChromiumBrowserRuntimeEnvironment(
            fileManager: fileManager,
            runtimeDownloadSession: URLSession(configuration: .ephemeral),
            loopbackCDPSession: URLSession(configuration: .ephemeral),
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux" },
            executableOverrideProvider: { nil },
            startupDeadline: {}
        )

        await ChromiumBrowserSession.removeOwnedProfileData(for: profileID, environment: environment)
        #expect(!fileManager.fileExists(atPath: paneDirectory.path))
    }

    @Test("Profile cleanup uses the injected file manager")
    func profileDataCleanupUsesInjectedFileManager() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-chromium-profile-injected-manager-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let profileID = UUID()
        let storage = ChromiumOwnedStorage(
            fileManager: fileManager,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux" }
        )
        let paneDirectory = try storage.profileDirectory(for: profileID, storageID: UUID())
        let injectedFileManager = NonDeletingFileManager()
        let environment = ChromiumBrowserRuntimeEnvironment(
            fileManager: injectedFileManager,
            runtimeDownloadSession: URLSession(configuration: .ephemeral),
            loopbackCDPSession: URLSession(configuration: .ephemeral),
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux" },
            executableOverrideProvider: { nil },
            startupDeadline: {}
        )

        await ChromiumBrowserSession.removeOwnedProfileData(for: profileID, environment: environment)

        #expect(fileManager.fileExists(atPath: paneDirectory.path))
    }

    @Test("Runtime lookup selects only the pinned version and architecture")
    func runtimeLookupIsArtifactSpecific() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-runtime-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ChromiumOwnedStorage(
            fileManager: .default,
            applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.example.cmux" }
        )
        let store = ChromiumRuntimeArtifactStore(
            fileManager: .default,
            urlSession: .shared,
            executableOverrideProvider: { nil },
            storage: storage
        )
        let artifact = ChromiumRuntimeArtifact(
            version: "current",
            platform: "mac-test",
            downloadURL: URL(string: "https://example.invalid/chromium.zip")!
        )
        let manifest = ChromiumRuntimeManifest(
            version: artifact.version,
            artifacts: [ChromiumRuntimeManifest.processArchitecture: artifact]
        )
        let runtimeRoot = try storage.runtimeDirectory()
        let obsolete = runtimeRoot
            .appendingPathComponent("obsolete/mac-test", isDirectory: true)
            .appendingPathComponent("chrome", isDirectory: false)
        try FileManager.default.createDirectory(
            at: obsolete.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: obsolete.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: obsolete.path)
        #expect(store.installedExecutable(manifest: manifest) == nil)

        let current = runtimeRoot
            .appendingPathComponent("current/mac-test", isDirectory: true)
            .appendingPathComponent("chrome", isDirectory: false)
        try FileManager.default.createDirectory(
            at: current.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: current.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: current.path)
        #expect(
            store.installedExecutable(manifest: manifest)?.resolvingSymlinksInPath() ==
                current.resolvingSymlinksInPath()
        )
    }

    @Test("CDP values preserve nested JSON")
    func cdpValueRoundTrip() throws {
        let value: CDPValue = .object([
            "ok": .bool(true),
            "count": .number(2),
            "items": .array([.string("a"), .null]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CDPValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Navigation history selects adjacent CDP entry identifiers")
    func navigationHistoryTraversal() throws {
        let history = try ChromiumNavigationHistory(.object([
            "currentIndex": .number(1),
            "entries": .array([
                .object(["id": .number(101)]),
                .object(["id": .number(205)]),
                .object(["id": .number(309)]),
            ]),
        ]))

        #expect(history.canGoBack)
        #expect(history.canGoForward)
        #expect(history.targetEntryID(offset: -1) == 101)
        #expect(history.targetEntryID(offset: 1) == 309)
        #expect(history.targetEntryID(offset: 2) == nil)
    }

    @Test("Document title observer accepts only its renderer binding")
    func documentTitleBinding() {
        let observation = ChromiumDocumentTitleObservation()
        let matching = CDPEvent(
            method: "Runtime.bindingCalled",
            params: .object([
                "name": .string("__cmuxChromiumTitleChanged"),
                "payload": .string("Updated SPA title"),
            ])
        )
        let unrelated = CDPEvent(
            method: "Runtime.bindingCalled",
            params: .object([
                "name": .string("otherBinding"),
                "payload": .string("ignored"),
            ])
        )
        #expect(observation.title(from: matching) == "Updated SPA title")
        #expect(observation.title(from: unrelated) == nil)
        #expect(observation.title(from: CDPEvent(method: "Page.loadEventFired")) == nil)
    }

    @Test("Navigation history exposes URL stacks in persistence order")
    func navigationHistoryURLs() throws {
        let history = try ChromiumNavigationHistory(.object([
            "currentIndex": .number(1),
            "entries": .array([
                .object(["id": .number(1), "url": .string("https://a.test")]),
                .object(["id": .number(2), "url": .string("https://b.test")]),
                .object(["id": .number(3), "url": .string("https://c.test")]),
            ]),
        ]))

        #expect(history.backURLs == [URL(string: "https://a.test")!])
        #expect(history.forwardURLs == [URL(string: "https://c.test")!])
    }

    @Test("Navigation history rejects malformed indices and entry identifiers")
    func navigationHistoryValidation() {
        #expect(throws: CDPError.self) {
            try ChromiumNavigationHistory(.object([
                "currentIndex": .number(3),
                "entries": .array([.object(["id": .number(1)])]),
            ]))
        }
        #expect(throws: CDPError.self) {
            try ChromiumNavigationHistory(.object([
                "currentIndex": .number(0),
                "entries": .array([.object(["id": .string("one")])]),
            ]))
        }
    }
}
