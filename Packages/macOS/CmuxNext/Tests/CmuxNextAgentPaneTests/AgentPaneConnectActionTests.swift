import AppKit
import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The location row's connect choices (``AgentPaneModel/runAction(_:)``): SSH…, New Cloud Machine
/// and Open Cloud… (the Cloud page at its storefront, `#/get`, which lists the plan's sizes) run their
/// app action on the person's fresh gesture in the pane, never on page script alone.
@MainActor
struct AgentPaneConnectActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func openCloudOpensTheCloudStorefrontOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return true }
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no page")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.openCloudPane"))["ok"] as? Bool == true)
        #expect(ran == ["palette.openCloudPane"])
        #expect(arguments == [["route": "/get"]], "Open Cloud… lands on the storefront, not the machine list")
    }

    @Test func otherConnectActionsRunWithoutArguments() async {
        let model = AgentPaneModel(host: NoHost())
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return true }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("newCloudMachine"))["ok"] as? Bool == true)
        #expect(arguments == [[:]])
    }

    /// Connect Phone… opens the Mobile Pairing page, on the person's gesture only.
    @Test func connectPhoneOpensMobilePairingOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, args in ran.append(id); #expect(args.isEmpty); return true }
        #expect(await model.respond(to: .runAction("palette.mobileConnect"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no page")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.mobileConnect"))["ok"] as? Bool == true)
        #expect(ran == ["palette.mobileConnect"])
    }

    /// A started chat's picker: Move to Cloud on a chat of this Mac, Bring Back Local on a Cloud
    /// chat, the same actions as the tab's right-click menu, on the person's gesture.
    @Test func moveAndBringBackRunOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, args in ran.append(id); #expect(args.isEmpty); return true }
        #expect(await model.respond(to: .runAction("cloudMove"))["ok"] as? Bool != true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("cloudMove"))["ok"] as? Bool == true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("cloudBringBack"))["ok"] as? Bool == true)
        #expect(ran == ["cloudMove", "cloudBringBack"])
    }

    /// An action the app did not run (turned off, or not available for this chat) is a failure, so
    /// the page can say so instead of nothing happening.
    @Test func anActionTheAppDidNotRunIsAFailure() async {
        let model = AgentPaneModel(host: NoHost())
        model.onRunAction = { _, _ in false }
        model.transport.gestures.record()
        let reply = await model.respond(to: .runAction("cloudBringBack"))
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
    }

    /// Which move a started chat's picker offers is the app's call: `pane.tabState` reports the moves
    /// the chat's own right-click menu offers now (the App hides Bring Back Local on a chat no move
    /// from this Mac put on its machine, and Move to Cloud on a chat of another machine).
    @Test func tabStateReportsTheMovesTheChatMenuOffers() async {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["cloudMove", "cloudBringBack"] { registry.bind(id, invoke: { _ in }) }
        registry.context = ActionContext(rawValue: .max)
        let model = AgentPaneModel(host: NoHost())
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() })
        var hidden: Set<ActionID> = ["cloudBringBack"]
        model.chatMenuItems = {
            let entries = ContextMenuCatalog.shared.entries(for: .agentChat, removing: hidden)
            let menu = registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: "tab_chat"),
                                                entries: entries, implied: [])
            let items = menu.items
            menu.removeAllItems()
            return items
        }
        let moves = { (await model.respond(to: .tabState(refresh: false))["value"] as? [String: Any])?["moves"] as? [String] }
        #expect(await moves() == ["cloudMove"])
        hidden = ["cloudMove"]
        #expect(await moves() == ["cloudBringBack"])
        hidden = ["cloudMove", "cloudBringBack"]
        #expect(await moves() == [])
    }
}
