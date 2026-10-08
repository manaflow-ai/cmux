import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneCustomizationTests {
    private let registry = #"window.cmuxAcpmuxRegistry.register("message");"#

    private func makeDirectory(_ files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agent-pane-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    /// Runs `customization`'s scripts, each on its own like
    /// `evaluateJavaScript`, against a stand-in page that records what
    /// reached its registry and bridge.
    private func run(_ customization: AgentPaneCustomization, times: Int = 1) throws -> [String] {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        var calls = [];
        window.cmuxAcpmuxRegistry = { register: function (kind) { calls.push("register:" + kind); } };
        window.cmuxAcpmuxBridge = { applyCustomization: function (value) { calls.push("apply:" + JSON.stringify(value)); } };
        """)
        for _ in 0..<times {
            for script in customization.scripts() {
                context.evaluateScript(script)
            }
        }
        return (context.objectForKeyedSubscript("calls").toArray() ?? []).compactMap { $0 as? String }
    }

    @Test func readsAllThreeFiles() throws {
        let directory = try makeDirectory([
            "theme.css": ".acpmux-row { color: red; }",
            "layout.json": #"{ "density": "compact", "gutter": 4 }"#,
            "registry.js": registry,
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let customization = AgentPaneCustomization(directory: directory)
        #expect(customization == AgentPaneCustomization(
            themeCSS: ".acpmux-row { color: red; }",
            registryJS: registry,
            layoutJSON: #"{"density":"compact","gutter":4}"#
        ))
        #expect(try run(customization) == [
            "register:message",
            #"apply:{"themeCSS":".acpmux-row { color: red; }","layout":{"density":"compact","gutter":4}}"#,
        ])
    }

    @Test func missingFilesAreOmittedNotFatal() throws {
        let directory = try makeDirectory(["theme.css": "body { margin: 0; }"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let customization = AgentPaneCustomization(directory: directory)
        #expect(customization == AgentPaneCustomization(themeCSS: "body { margin: 0; }"))
        #expect(try run(customization) == [#"apply:{"themeCSS":"body { margin: 0; }","layout":{}}"#])
        let missing = directory.appending(path: "missing", directoryHint: .isDirectory)
        #expect(AgentPaneCustomization(directory: missing).isEmpty)
    }

    @Test(arguments: ["[1, 2]", "{ nope", "\"text\"", ""])
    func invalidLayoutJSONIsDropped(_ layout: String) throws {
        let directory = try makeDirectory(["theme.css": "a {}", "layout.json": layout])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AgentPaneCustomization(directory: directory) == AgentPaneCustomization(themeCSS: "a {}"))
        #expect(AgentPaneCustomization(layoutJSON: layout).layoutJSON == nil)
    }

    @Test func scriptRunsRegistryBeforeApplyCustomization() throws {
        let customization = AgentPaneCustomization(themeCSS: "a {}", registryJS: registry)
        #expect(try run(customization) == ["register:message", #"apply:{"themeCSS":"a {}","layout":{}}"#])
    }

    /// The pane replays the customization on every load, handshake and file
    /// change, so a `registry.js` with top-level declarations must run again
    /// in the same page.
    @Test func registryWithDeclarationsReplaysInTheSamePage() throws {
        let declaring = """
        const registry = window.cmuxAcpmuxRegistry;
        class Row {}
        registry.register("message");
        """
        let customization = AgentPaneCustomization(registryJS: declaring)
        let apply = #"apply:{"themeCSS":"","layout":{}}"#
        #expect(try run(customization, times: 2) == ["register:message", apply, "register:message", apply])
    }

    @Test func aBrokenRegistryStillAppliesTheTheme() throws {
        for broken in ["throw new Error('renderer bug');", "}{ not javascript"] {
            let customization = AgentPaneCustomization(themeCSS: "a {}", registryJS: broken)
            #expect(try run(customization) == [#"apply:{"themeCSS":"a {}","layout":{}}"#])
        }
    }

    @Test func deletedThemeClearsTheStyle() throws {
        let directory = try makeDirectory(["theme.css": "a {}"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AgentPaneCustomization(directory: directory).themeCSS == "a {}")
        try FileManager.default.removeItem(at: directory.appending(path: "theme.css"))
        let customization = AgentPaneCustomization(directory: directory)
        #expect(customization.isEmpty)
        #expect(try run(customization) == [#"apply:{"themeCSS":"","layout":{}}"#])
    }

    @Test func themeTextCannotEscapeTheCall() throws {
        let hostile = #"a::after { content: "\"}); window.pwned = 1; //" }"# + "\n</script>\u{2028}"
        let customization = AgentPaneCustomization(themeCSS: hostile)
        let calls = try run(customization)
        let json = try #require(calls.first?.dropFirst("apply:".count))
        let value = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(calls.count == 1)
        #expect(value["themeCSS"] as? String == hostile)
    }

    @Test func directoryFollowsTheConfigFile() {
        let configFile = URL(fileURLWithPath: "/Users/me/.config/cmux/cmux.json")
        #expect(AgentPaneCustomization.directory(configFile: configFile) == URL(filePath: "/Users/me/.config/cmux/agent-pane", directoryHint: .isDirectory))
        let custom = URL(fileURLWithPath: "/tmp/cmux-dev/settings.json")
        #expect(AgentPaneCustomization.directory(configFile: custom) == URL(filePath: "/tmp/cmux-dev/agent-pane", directoryHint: .isDirectory))
    }
}
