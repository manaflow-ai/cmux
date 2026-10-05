import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The prewarmed new tab page (plans/cmux-next/new-tab.md section 2.2): a
/// spare loads with an empty new tab context; Cmd-T adopts it and hands it
/// the real one, so a reload shows the adopted page and the page remounts.
@Suite struct AgentPaneSpareTests {
    static let spare = AgentPaneNewTab(kind: .agent, layout: .b)
    static let real = AgentPaneNewTab(kind: .agent, cwd: "/src/app", location: "~/src/app", layout: .b, lastAgent: "codex")

    @Test func adoptingReplacesTheContextTheHandshakeCarries() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: Self.spare)
        model.adoptNewTab(Self.real)
        #expect(model.newTab == Self.real)
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        let newTab = try #require(value["newTab"] as? [String: Any])
        #expect(newTab["location"] as? String == "~/src/app")
        #expect(value["cwd"] as? String == "/src/app")
    }

    @Test func aChatCannotBeAdoptedAsANewTabPage() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: Self.spare)
        _ = await model.respond(to: .persistSession("s-1"))
        model.adoptNewTab(Self.real)
        #expect(model.newTab == nil)
    }

    @Test func theViewDispatchesTheContextToThePage() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost(), newTab: Self.spare)))
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.adoptNewTab(Self.real)
        let script = try #require(scripts.first { $0.contains("acpmux-newtab-adopt") })
        #expect(script.contains(#""location":"~\/src\/app""#) || script.contains(#""location":"~/src/app""#))
        #expect(view.model.newTab == Self.real)
    }
}

/// `newTab.submit` with an agent: the chat it opens starts on that harness.
@Suite struct AgentPaneSeedHarnessTests {
    @Test func theSeedsHarnessReachesTheHandshake() async throws {
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "/src", prompt: "fix it", harness: "codex"))
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: seed)
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["harness"] as? String == "codex")
        #expect(value["prompt"] as? String == "fix it")
    }
}

/// R81 recycle: only a strictly untouched new tab page goes back to the
/// pool; boot traffic does not touch it, user input and any other op do.
@Suite struct AgentPaneTouchedTests {
    @Test func bootTrafficKeepsThePageUntouched() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        _ = await model.respond(to: .ready)
        _ = await model.respond(to: .framePacing([16.7]))
        _ = await model.respond(to: .renderRate(true))
        _ = await model.respond(to: .checkpointAvailability(false))
        // A request the host refuses changed nothing.
        _ = await model.respond(to: .unsupported("page.probe"))
        #expect(model.userTouched == false)
        _ = await model.respond(to: .touched)
        #expect(model.userTouched == true)
    }

    @Test func anyOtherOpTouchesThePage() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        model.onTypeAhead = { _ in }
        _ = await model.respond(to: .typeAhead("ls"))
        #expect(model.userTouched == true)
        let request = AgentPaneRequest(body: ["method": "newTab.touched", "params": [:]] as [String: Any])
        #expect(request == .touched)
    }
}
