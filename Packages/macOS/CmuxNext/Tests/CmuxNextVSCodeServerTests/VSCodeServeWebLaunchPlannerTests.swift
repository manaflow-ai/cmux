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
            homeDirectory: Self.home, environment: ["ELECTRON_RUN_AS_NODE": "1"],
            isExecutable: { $0 == "\(Self.cache)/bbb/bin/code-server" || $0 == "\(Self.cache)/aaa/bin/code-server" || $0.hasSuffix("code-tunnel") },
            data: { $0.path == "\(Self.cache)/lru.json" ? Data(#"["../evil","bbb","aaa"]"#.utf8) : nil },
            contents: { _ in [] }, modificationDate: { _ in nil }
        )
        let launch = try #require(planner.launch(vscode: Self.vscode, connectionTokenFile: Self.token))
        #expect(launch.executableURL.path == "\(Self.cache)/bbb/bin/code-server")
        #expect(launch.arguments == ["--accept-server-license-terms", "--host", "127.0.0.1", "--port", "0", "--connection-token-file", "/tmp/token"])
        #expect(launch.environment["ELECTRON_RUN_AS_NODE"] == nil)
    }

    @Test func withoutLRUTheNewestCachedServerWinsInTheProductsDataFolder() throws {
        let insiders = "/Users/me/.vscode-insiders/cli/serve-web"
        let planner = VSCodeServeWebLaunchPlanner(
            homeDirectory: Self.home, environment: [:],
            isExecutable: { $0.hasSuffix("bin/code-server") },
            data: { $0.path.hasSuffix("Contents/Resources/app/product.json") ? Data(#"{"dataFolderName":".vscode-insiders"}"#.utf8) : nil },
            contents: { $0.path == insiders ? [URL(fileURLWithPath: "\(insiders)/old"), URL(fileURLWithPath: "\(insiders)/new")] : [] },
            modificationDate: { $0.path.contains("/new/") ? Date(timeIntervalSince1970: 200) : Date(timeIntervalSince1970: 100) }
        )
        let launch = try #require(planner.launch(vscode: Self.vscode, connectionTokenFile: Self.token))
        #expect(launch.executableURL.path == "\(insiders)/new/bin/code-server")
    }

    @Test func noCacheFallsBackToTheBundledCLIAndNoCLIMeansNoServer() throws {
        let bundled = VSCodeServeWebLaunchPlanner(homeDirectory: Self.home, environment: [:], isExecutable: { $0.hasSuffix("code-tunnel") },
                                                  data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil })
        #expect(bundled.canServe(vscode: Self.vscode))
        let launch = try #require(bundled.launch(vscode: Self.vscode, connectionTokenFile: Self.token))
        #expect(launch.arguments.first == "serve-web")
        #expect(launch.environment["ELECTRON_RUN_AS_NODE"] == "1")
        let none = VSCodeServeWebLaunchPlanner(homeDirectory: Self.home, environment: [:], isExecutable: { _ in false },
                                               data: { _ in nil }, contents: { _ in [] }, modificationDate: { _ in nil })
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
