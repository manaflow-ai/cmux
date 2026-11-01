import Foundation
import Testing
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextAgentPane

/// Session Info's Remote Control switch (``AgentPaneRemoteControl``): the page gets the iPhone
/// host's switch, or null (no row) while this Mac cannot serve phones; `pane.setRemoteControl {on}`
/// writes it only from the person's own click, for a chat on this Mac.
@Suite(.serialized)
@MainActor
struct AgentPaneRemoteControlTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class WriteBox { var writes: [Bool] = [] }

    @Test func theRequestTakesOneBoolAndNothingElse() {
        for on in [true, false] {
            #expect(AgentPaneRequest(body: ["method": "pane.setRemoteControl", "params": ["on": on]]) == .remoteControl(on: on))
        }
        for params: [String: Any] in [[:], ["on": "true"], ["on": NSNull()], ["on": true, "session": "s"]] {
            #expect(AgentPaneRequest(body: ["method": "pane.setRemoteControl", "params": params]) == .unsupported("pane.setRemoteControl"))
        }
        #expect(AgentPageOps.methods["pane.setRemoteControl"] == "pane.setRemoteControl")
    }

    @Test func thePageGetsTheSwitchOrNull() {
        #expect(AgentPaneRemoteControl.event(.init(on: true)) == AgentPageEvent(kind: "remoteControl", value: ["on": .bool(true)]))
        #expect(AgentPaneRemoteControl.event(.init(on: false)) == AgentPageEvent(kind: "remoteControl", value: ["on": .bool(false)]))
        #expect(AgentPaneRemoteControl.event(nil) == AgentPageEvent(kind: "remoteControl", value: .null))
        // The legacy host has no event stream: it gets the same value through the page's bridge.
        #expect(AgentPaneRemoteControl.script(.init(on: true)) == "window.cmuxAcpmuxBridge?.applyRemoteControl?.({\"on\":true});")
        #expect(AgentPaneRemoteControl.script(nil) == "window.cmuxAcpmuxBridge?.applyRemoteControl?.(null);")
    }

    @Test func onlyThePersonsClickWritesIt() async {
        let control = AgentPaneRemoteControl()
        let box = WriteBox()
        control.set = { on in box.writes.append(on) }
        control.state = { .init(on: false) }

        let gestures = AgentPaneUserGestures(now: { 100 })
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: gestures))
        model.remoteControl = control
        let refused = await model.respond(to: .remoteControl(on: true))
        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(box.writes.isEmpty)

        gestures.record(click: true)
        let accepted = await model.respond(to: .remoteControl(on: true))
        #expect(accepted["ok"] as? Bool == true)
        #expect(box.writes == [true])
    }

    @Test func noSwitchOrARemoteChatWritesNothing() async {
        let control = AgentPaneRemoteControl()
        let box = WriteBox()
        control.set = { on in box.writes.append(on) }

        // This Mac cannot serve phones: no row, and a call changes nothing.
        control.state = { nil }
        let model = AgentPaneModel(host: NoHost())
        model.remoteControl = control
        let unavailable = await model.respond(to: .remoteControl(on: true), userGesture: true)
        #expect(unavailable["ok"] as? Bool == false)

        // A chat on another machine: this Mac's phone access is not its to change.
        control.state = { .init(on: false) }
        model.remoteChat = true
        let remote = await model.respond(to: .remoteControl(on: true), userGesture: true)
        #expect(remote["ok"] as? Bool == false)
        #expect(box.writes.isEmpty)
    }

    /// A model with no switch (no iPhone host given) writes nothing.
    @Test func aModelWithNoSwitchWritesNothing() async {
        let model = AgentPaneModel(host: NoHost())
        let reply = await model.respond(to: .remoteControl(on: true), userGesture: true)
        #expect(reply["ok"] as? Bool == false)
    }

    @Test func aPageScriptCannotCallItThroughTheSharedHost() async throws {
        let provider = AgentPageProvider { _ in nil }
        do {
            _ = try await provider.call(AgentPageOps.namespace + "pane.setRemoteControl", params: .object(["on": .bool(true)]),
                                        context: PageCallContext(page: PageDescriptor.agent.id))
            Issue.record("a script page call changed which phones reach this Mac")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
    }
}
