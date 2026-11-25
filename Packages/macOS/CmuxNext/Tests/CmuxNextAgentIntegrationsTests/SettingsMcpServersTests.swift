@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > MCP Servers: the rows come from `optchat-chief integrations --json list`; Remove runs
/// `--json remove <name>` and reads the list again; Sign In runs `--json signin <name>`, opens the
/// sign-in page it prints (only an http(s) page) and reads the list again when it ends. Nothing
/// changes without the person's click.
@MainActor struct SettingsMcpServersTests {
    nonisolated static let chief = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/optchat-chief")

    nonisolated static let list = #"""
    {"servers":[
      {"name":"linear","kind":"remote","address":"https://mcp.linear.app/mcp","publisher":"linear.app","verified":true,"state":"connected","problem":null,"scope":"agents","tools":23,"addedMs":1},
      {"name":"slack","kind":"remote","address":"https://mcp.slack.com/mcp","publisher":"slack.com","verified":true,"state":"signInNeeded","problem":null,"scope":"chief","tools":0,"addedMs":2}
    ]}
    """#

    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    nonisolated static let script = PageCallContext(page: "cmux.settings")

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var environments: [[String: String]] = []
        var list = SettingsMcpServersTests.list
        var removeReply: (Int32, Data, Data) = (0, Data(#"{"status":"removed"}"#.utf8), Data())
        var signInLines: [String] = [#"{"status":"waiting","page":"https://slack.com/oauth/v2_user/authorize?x=1"}"#, #"{"status":"connected"}"#]
    }

    static func model(_ recorder: Recorder, home: URL? = nil, opened: @escaping @MainActor (URL) -> Void = { _ in }) -> SettingsMcpServers {
        SettingsMcpServers(
            chief: { SettingsMcpServersTests.chief },
            home: { home },
            openPage: opened,
            runCLI: { _, arguments, environment in
                recorder.calls.append(arguments)
                recorder.environments.append(environment)
                if arguments.last == "list" { return (0, Data(recorder.list.utf8), Data()) }
                return recorder.removeReply
            },
            streamCLI: { _, arguments, environment, line in
                recorder.calls.append(arguments)
                recorder.environments.append(environment)
                for text in recorder.signInLines { if let value = try? JSONValue.parse(Data(text.utf8)) { line(value) } }
                return 0
            })
    }

    /// The page reads and changes the store this build's agents use: the helper runs with the
    /// app's acpmux home (a DEV or tagged build has its own), not whatever home the app inherited.
    @Test func theHelperRunsInTheAppsOwnHome() async throws {
        let recorder = Recorder()
        let home = URL(fileURLWithPath: "/Users/me/.acpmux/builds/com.cmuxterm.app.debug.x", isDirectory: true)
        let model = Self.model(recorder, home: home)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "signin", "name": "slack"], context: Self.click)
        for _ in 0..<200 where recorder.calls.count < 3 { await Task.yield() }
        _ = try await model.run(["action": "remove", "name": "linear"], context: Self.click)
        #expect(recorder.environments.count >= 4)
        #expect(recorder.environments.allSatisfy { $0 == ["ACPMUX_HOME": home.path] })
        // No home known: the helper keeps the app's environment as it is.
        let plain = Recorder()
        _ = try await Self.model(plain).run(["action": "refresh"], context: Self.script)
        #expect(plain.environments == [[:]])
    }

    @Test func listsEachServerAndRunsNothingBeforeAsked() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        #expect(recorder.calls.isEmpty)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        #expect(recorder.calls == [["integrations", "--json", "list"]])
        let rows = try #require(model.state["servers"]?.arrayValue)
        #expect(rows.map { $0["name"]?.stringValue } == ["linear", "slack"])
        #expect(rows.map { $0["state"]?.stringValue } == ["connected", "signInNeeded"])
        #expect(rows.map { $0["scope"]?.stringValue } == ["agents", "chief"])
        #expect(rows[0]["tools"]?.intValue == 23)
        #expect(model.state["problem"] == .null)
    }

    @Test func removeNeedsAClickThenRunsTheCLIAndReadsAgain() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        recorder.calls = []
        await #expect(throws: PageError.self) { try await model.run(["action": "remove", "name": "linear"], context: Self.script) }
        await #expect(throws: PageError.self) { try await model.run(["action": "remove", "name": "--all"], context: Self.click) }
        #expect(recorder.calls.isEmpty)
        recorder.list = #"{"servers":[]}"#
        _ = try await model.run(["action": "remove", "name": "linear"], context: Self.click)
        #expect(recorder.calls == [["integrations", "--json", "remove", "linear"], ["integrations", "--json", "list"]])
        #expect(model.state["servers"]?.arrayValue?.isEmpty == true)
    }

    @Test func aRefusedRemoveShowsTheCLIsWords() async throws {
        let recorder = Recorder()
        recorder.removeReply = (1, Data(#"{"status":"failed","why":"mcp remove: no server linear"}"#.utf8), Data())
        let model = Self.model(recorder)
        _ = try await model.run(["action": "refresh"], context: Self.script)
        _ = try await model.run(["action": "remove", "name": "linear"], context: Self.click)
        let linear = try #require(model.state["servers"]?.arrayValue?.first)
        #expect(linear["error"]?.stringValue == "mcp remove: no server linear")
    }

    @Test func signInOpensTheServicesPageAndReadsTheListWhenItEnds() async throws {
        let recorder = Recorder()
        var opened: [URL] = []
        let model = Self.model(recorder) { opened.append($0) }
        _ = try await model.run(["action": "refresh"], context: Self.script)
        await #expect(throws: PageError.self) { try await model.run(["action": "signin", "name": "slack"], context: Self.script) }
        recorder.list = Self.list.replacingOccurrences(of: "signInNeeded", with: "connected")
        _ = try await model.run(["action": "signin", "name": "slack"], context: Self.click)
        for _ in 0..<200 where model.state["servers"]?.arrayValue?.last?["state"]?.stringValue != "connected" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(opened.map(\.absoluteString) == ["https://slack.com/oauth/v2_user/authorize?x=1"])
        #expect(recorder.calls.contains(["integrations", "--json", "signin", "slack"]))
        let slack = try #require(model.state["servers"]?.arrayValue?.last)
        #expect(slack["state"]?.stringValue == "connected")
        #expect(slack["signingIn"] == .bool(false))
    }

    @Test func onlyAWebPageOpens() {
        #expect(SettingsMcpServers.isWebPage(URL(string: "https://linear.app/oauth/authorize")!))
        #expect(!SettingsMcpServers.isWebPage(URL(string: "file:///etc/passwd")!))
        #expect(!SettingsMcpServers.isWebPage(URL(string: "cmux://settings")!))
    }

    /// A build without the helper beside its CLI says so ("unavailable"), not "failed"; one with it
    /// finds it. Only an executable file counts.
    @Test func aBuildWithoutTheHelperShowsUnavailable() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mcp-servers-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appending(path: "cmux", directoryHint: .notDirectory)
        let model = SettingsMcpServers(cli: { cli }, home: { nil }, openPage: { _ in })
        await model.refresh()
        #expect(model.state["problem"] == .string("unavailable"))
        #expect(model.state["servers"] == .array([]))

        let helper = folder.appending(path: "optchat-chief", directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        #expect(await SettingsMcpServers.chief(besideCLI: cli) == nil, "not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(await SettingsMcpServers.chief(besideCLI: cli) == helper)
        #expect(await SettingsMcpServers.chief(besideCLI: nil) == nil)
    }
}
