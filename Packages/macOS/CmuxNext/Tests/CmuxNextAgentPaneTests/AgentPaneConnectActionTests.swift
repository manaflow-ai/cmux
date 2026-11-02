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

    /// Picking the strip's red machine reconnects it: the header's own Reconnect, on a gesture only
    /// (the host resolves the tab's machine; the page names none).
    @Test func machineReconnectRunsOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, args in ran.append(id); #expect(args.isEmpty); return true }
        #expect(await model.respond(to: .runAction("machine.reconnect"))["ok"] as? Bool != true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("machine.reconnect"))["ok"] as? Bool == true)
        #expect(ran == ["machine.reconnect"])
    }

    @Test func refusedCloudCreationDoesNotLoseIntentToStandaloneSignIn() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return false }
        model.transport.gestures.record()
        let reply = await model.respond(to: .runAction("newCloudMachine"))
        #expect(reply["ok"] as? Bool != true)
        #expect(ran == ["newCloudMachine"])
    }

    /// The signed-out picker's Sign in for Cloud runs Sign In itself, on a gesture only: it never
    /// goes through New Cloud Machine, which would create a machine once sign-in finished.
    @Test func cloudSignInRunsSignInOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, args in ran.append(id); #expect(args.isEmpty); return true }
        #expect(await model.respond(to: .runAction("palette.auth.signIn"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no sign-in")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.auth.signIn"))["ok"] as? Bool == true)
        #expect(ran == ["palette.auth.signIn"])
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

    /// The + menu's Search chats and Search pages open the command palette's chats and History
    /// search pages without a gesture; an action outside the pane's table stays refused.
    @Test func paletteSearchPagesRunWithoutAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, args in ran.append(id); #expect(args.isEmpty); return true }
        #expect(await model.respond(to: .runAction("agentPane.searchChats"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .runAction("history.search"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .runAction("searchFiles"))["ok"] as? Bool != true)
        #expect(ran == ["agentPane.searchChats", "history.search"])
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

    @Test func titleMoveTargetsAreAdvertisedAndValidated() async {
        let model = AgentPaneModel(host: NoHost())
        var moved: (machine: String, session: String)?
        model.header = AgentPaneHeaderHooks(
            run: { _, _ in },
            tabState: { AgentPaneHeaderState() },
            moveTargets: { [AgentPaneMoveTarget(id: "vm-build", label: "Build Mac", status: "running")] },
            moveToMachine: { id, session in moved = (id, session); return true },
        )
        let state = await model.respond(to: .tabState(refresh: false))["value"] as? [String: Any]
        let targets = state?["moveTargets"] as? [[String: Any]]
        #expect(targets?.first?["id"] as? String == "vm-build")
        #expect(await model.respond(to: .moveToMachine("vm-build", session: "chat-a"))["ok"] as? Bool != true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .moveToMachine("vm-build", session: "chat-a"))["ok"] as? Bool == true)
        #expect(moved?.machine == "vm-build")
        #expect(moved?.session == "chat-a")
        model.transport.gestures.record()
        #expect(await model.respond(to: .moveToMachine("not-advertised", session: "chat-a"))["ok"] as? Bool != true)
    }

    /// The move names the chat whose title menu offered it: a request without one is refused at
    /// decoding, so the host never falls back to whatever the tab shows when it handles it.
    @Test func titleMoveRequestCarriesItsChat() {
        let bound = AgentPaneRequest(body: ["method": "pane.moveToMachine", "params": ["machine": "vm-build", "session": "chat-a"]])
        #expect(bound == .moveToMachine("vm-build", session: "chat-a"))
        let unbound = AgentPaneRequest(body: ["method": "pane.moveToMachine", "params": ["machine": "vm-build"]])
        #expect(unbound == .unsupported("pane.moveToMachine"))
    }

    /// The host refuses the move when the tab shows another chat by now (the person switched
    /// before the request was handled): only the menu's own chat moves.
    @Test func titleMoveRefusedWhenTheChatChanged() async {
        let model = AgentPaneModel(host: NoHost())
        var shown = "chat-a"
        var moved: [String] = []
        model.header = AgentPaneHeaderHooks(
            run: { _, _ in },
            tabState: { AgentPaneHeaderState() },
            moveTargets: { [AgentPaneMoveTarget(id: "vm-build", label: "Build Mac")] },
            moveToMachine: { _, session in
                guard session == shown else { return false }
                moved.append(session)
                return true
            },
        )
        shown = "chat-b"
        model.transport.gestures.record()
        #expect(await model.respond(to: .moveToMachine("vm-build", session: "chat-a"))["ok"] as? Bool != true)
        #expect(moved.isEmpty)
    }

    /// The title menu's Bring Back Local names its chat: the app runs it only while the tab still
    /// shows that chat, so a switch before the request is handled brings nothing back.
    @Test func sessionBoundActionRunsOnlyForTheShownChat() async {
        let model = AgentPaneModel(host: NoHost())
        var shown = "chat-a"
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return true }
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            showsChat: { $0 == shown })
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("cloudBringBack", session: "chat-a"))["ok"] as? Bool == true)
        #expect(ran == ["cloudBringBack"])
        shown = "chat-b"
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("cloudBringBack", session: "chat-a"))["ok"] as? Bool != true)
        #expect(ran == ["cloudBringBack"], "the newly shown chat is not brought back")
    }

    @Test func sessionBoundActionDecodesItsChat() {
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "cloudBringBack", "session": "chat-a"]])
            == .runAction("cloudBringBack", session: "chat-a"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "cloudBringBack"]])
            == .runAction("cloudBringBack"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "cloudBringBack", "session": ""]])
            == .unsupported("action.run"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "cloudBringBack", "session": 7]])
            == .unsupported("action.run"))
    }
}
