import CmuxNextVSCodeServer
import Foundation
import Testing

/// Which binary serves VS Code in the browser: a `code-server` that `serve-web` already cached
/// (most recently used first, from `lru.json`, else the newest), or the app's bundled `code-tunnel`
/// CLI running `serve-web`. The server's output names its Web UI URL; a folder opens through
/// that URL's `folder` query.
@Suite struct VSCodeServeWebLaunchPlannerTests {
    static let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
    static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    static let token = URL(fileURLWithPath: "/tmp/token")
    static let cache = "/Users/me/.vscode/cli/serve-web"

    @Test func theMostRecentlyUsedCachedCodeServerWinsAndRunsWithoutElectronAsNode() throws {
        let planner = VSCodeServeWebLaunchPlanner(
            homeDirectory: Self.home, environment: [
                "ELECTRON_RUN_AS_NODE": "1",
                "HOME": "/Users/me",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "NODE_OPTIONS": "--require /tmp/untrusted.js",
                "OPENAI_API_KEY": "ambient-secret",
                "PATH": "/usr/bin:/bin",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
            ],
            isExecutable: { $0 == "\(Self.cache)/bbb/bin/code-server" || $0 == "\(Self.cache)/aaa/bin/code-server" || $0.hasSuffix("code-tunnel") },
            data: { $0.path == "\(Self.cache)/lru.json" ? Data(#"["../evil","bbb","aaa"]"#.utf8) : nil },
            contents: { _ in [] }, modificationDate: { _ in nil }, executableTrust: { _ in true }
        )
        let launch = try #require(planner.launch(vscode: Self.vscode, connectionTokenFile: Self.token))
        #expect(launch.executableURL.path == "\(Self.cache)/bbb/bin/code-server")
        #expect(launch.arguments == ["--accept-server-license-terms", "--host", "127.0.0.1", "--port", "0", "--connection-token-file", "/tmp/token"])
        #expect(launch.environment == [
            "HOME": "/Users/me",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
        ])
    }

    @Test func symlinkedCachedCodeServerIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vscode-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let serverDirectory = root.appendingPathComponent(".vscode/cli/serve-web/current/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("replacement")
        try "#!/bin/sh\nexit 0\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let server = serverDirectory.appendingPathComponent("code-server")
        try FileManager.default.createSymbolicLink(at: server, withDestinationURL: target)
        let planner = VSCodeServeWebLaunchPlanner(
            homeDirectory: root,
            environment: [:],
            data: { $0.path.hasSuffix("lru.json") ? Data(#"["current"]"#.utf8) : nil },
            contents: { _ in [] },
            modificationDate: { _ in nil }
        )

        #expect(planner.launch(vscode: root.appendingPathComponent("Visual Studio Code.app"), connectionTokenFile: Self.token) == nil)
    }

    @Test func withoutLRUTheNewestCachedServerWinsInTheProductsDataFolder() throws {
        let insiders = "/Users/me/.vscode-insiders/cli/serve-web"
        let planner = VSCodeServeWebLaunchPlanner(
            homeDirectory: Self.home, environment: [:],
            isExecutable: { $0.hasSuffix("bin/code-server") },
            data: { $0.path.hasSuffix("Contents/Resources/app/product.json") ? Data(#"{"dataFolderName":".vscode-insiders"}"#.utf8) : nil },
            contents: { $0.path == insiders ? [URL(fileURLWithPath: "\(insiders)/old"), URL(fileURLWithPath: "\(insiders)/new")] : [] },
            modificationDate: { $0.path.contains("/new/") ? Date(timeIntervalSince1970: 200) : Date(timeIntervalSince1970: 100) },
            executableTrust: { _ in true }
        )
        let launch = try #require(planner.launch(vscode: Self.vscode, connectionTokenFile: Self.token))
        #expect(launch.executableURL.path == "\(insiders)/new/bin/code-server")
    }

    @Test func noTrustedCacheRefusesTheBundledCLIAndNoCLIMeansNoServer() {
        let bundled = VSCodeServeWebLaunchPlanner(homeDirectory: Self.home, environment: [:], isExecutable: { $0.hasSuffix("code-tunnel") },
                                                  data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil },
                                                  executableTrust: { _ in true })
        #expect(!bundled.canServe(vscode: Self.vscode))
        #expect(bundled.launch(vscode: Self.vscode, connectionTokenFile: Self.token) == nil)
        let none = VSCodeServeWebLaunchPlanner(homeDirectory: Self.home, environment: [:], isExecutable: { _ in false },
                                               data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil },
                                               executableTrust: { _ in true })
        #expect(!none.canServe(vscode: Self.vscode))
        #expect(none.launch(vscode: Self.vscode, connectionTokenFile: Self.token) == nil)
    }

    @Test func theServerOutputNamesItsWebUIURL() {
        #expect(URL(vscodeServeWebOutput: "*\n* Web UI available at http://127.0.0.1:61234?tkn=abc\n")?.absoluteString == "http://127.0.0.1:61234?tkn=abc")
        #expect(URL(vscodeServeWebOutput: "Server bound to 127.0.0.1:61234") == nil)
    }

    @Test func aFolderReplacesAnyEarlierFolderQuery() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1/?tkn=t&folder=/old"))
        let url = try #require(base.vscodeServeWebURL(openingFolder: "/new"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "tkn", value: "t"), URLQueryItem(name: "folder", value: "/new")])
    }
}
