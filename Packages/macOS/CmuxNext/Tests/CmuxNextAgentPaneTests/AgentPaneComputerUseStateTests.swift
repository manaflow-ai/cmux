import AppKit
@testable import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The composer's `@computer-use` (CMUX-682): the App pushes Computer Use's state to every page as it
/// changes (`computerUseState`), so a send decides on it at once; when it is not ready, Set Up Computer
/// Use opens the onboarding step on the person's own key press or click in the pane.
@MainActor
struct AgentPaneComputerUseStateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func theSetupPhaseMapsToWhatThePageHolds() {
        #expect(AgentPaneComputerUseState(phase: "ready", granted: true) == .ready)
        #expect(AgentPaneComputerUseState(phase: "ready", granted: false) == .needsSetup, "a grant is missing")
        #expect(AgentPaneComputerUseState(phase: "starting", granted: false) == .starting)
        #expect(AgentPaneComputerUseState(phase: "disabled_by_policy", granted: false) == .disabled)
        // Setup can turn it on or restart it.
        for phase in ["off", "failed"] {
            #expect(AgentPaneComputerUseState(phase: phase, granted: false) == .needsSetup, "\(phase)")
        }
        // No cmux Remote in this build, or one of another version: setup cannot fix it (#48541).
        for phase in ["unavailable", "version_mismatch"] {
            #expect(AgentPaneComputerUseState(phase: phase, granted: false) == .unavailable, "\(phase)")
        }
    }

    @Test func thePageGetsTheStateAsItsRawValueAndNullWhileUnknown() {
        #expect(AgentPageEvent.computerUseState(.needsSetup).kind == "computerUseState")
        #expect(AgentPageEvent.computerUseState(.needsSetup).value == .string("needs_setup"))
        #expect(AgentPageEvent.computerUseState(.ready).value == .string("ready"))
        #expect(AgentPageEvent.computerUseState(.unavailable).value == .string("unavailable"))
        #expect(AgentPageEvent.computerUseState(nil).value == .null)
    }

    /// Review of #48024 (WebKit skips setup): with `agent.pageHost` off, the default, a page hears the
    /// state only through the old host's script, the hook computerUseState.ts installs.
    @Test func theOldHostGetsTheStateThroughThePagesHook() {
        #expect(AgentPaneComputerUse.oldHostScript(.needsSetup) == "window.cmuxAcpmuxComputerUseState?.(\"needs_setup\");")
        #expect(AgentPaneComputerUse.oldHostScript(.ready) == "window.cmuxAcpmuxComputerUseState?.(\"ready\");")
        #expect(AgentPaneComputerUse.oldHostScript(nil) == "window.cmuxAcpmuxComputerUseState?.(null);")
    }

    @Test func theFollowerKeepsTheLatestState() {
        let follower = AgentPaneComputerUse(read: nil)
        #expect(follower.state == nil)
        follower.set(.needsSetup)
        #expect(follower.state == .needsSetup)
        follower.set(.ready)
        #expect(follower.state == .ready)
    }

    /// The pane's own WebKit host (dev-server panes, the bundled WebKit fallback) has no page host
    /// replay: its page gets the state at each handshake (AgentPaneBridge `ready`) and every later
    /// change, as a script, never nothing (the page sends while it knows no state).
    @Test func thePanesOwnWebKitHostGetsTheStateAtItsHandshakeAndOnEveryChange() async throws {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost())
        let follower = AgentPaneComputerUse(read: nil)
        model.computerUse = follower
        let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
        try #require(view.pageEvents == nil, "setup: not the pane's own WebKit host")
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        let pushes = { scripts.filter { $0.hasPrefix("window.cmuxAcpmuxComputerUseState?.(") } }
        follower.set(.needsSetup)
        #expect(pushes().isEmpty, "a page that never shook hands was told")

        _ = await AgentPaneBridge(view: view).reply(to: .ready)
        #expect(pushes() == [AgentPaneComputerUse.oldHostScript(.needsSetup)])
        #expect(pushes().last == "window.cmuxAcpmuxComputerUseState?.(\"needs_setup\");")

        follower.set(.ready)
        #expect(pushes().last == "window.cmuxAcpmuxComputerUseState?.(\"ready\");", "a change missed the page")
        // A reloaded document shakes hands again and gets the state as it is now.
        _ = await AgentPaneBridge(view: view).reply(to: .ready)
        #expect(pushes().count == 3 && pushes().last == AgentPaneComputerUse.oldHostScript(.ready))
        view.close()
    }

    @Test func thePaneNoLongerAnswersAStateQuery() {
        // The page no longer asks: the state comes as a push.
        let request = AgentPaneRequest(body: ["method": "chat.computerUse.state", "params": [String: Any]()])
        #expect(request == .unsupported("chat.computerUse.state"))
    }

    /// Review round 2 of #48024: Set Up spends a key press or click from just now, once. A deferred request (a held
    /// send that waited) cannot spend the half-minute credit that unrelated typing leaves.
    @Test func setUpComputerUseRunsOnlyOnThePersonsGestureFromJustNow() async {
        final class Clock { var now: TimeInterval = 100 }
        let clock = Clock()
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now })))
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return .ran }
        let setUp = { await model.respond(to: .runAction(AgentPaneComputerUseState.setupAction))["ok"] as? Bool == true }
        #expect(!(await setUp()))
        #expect(ran.isEmpty, "no gesture, no onboarding step")
        // Return in the composer: the key that sent counts, not only a click.
        model.transport.gestures.record(press: true)
        #expect(await setUp())
        #expect(ran == ["palette.computerUse.setup"])
        #expect(!(await setUp()), "one key press opened Set Up twice")
        // A Return older than the answer window still leaves the generic credit, but Set Up does not take it.
        model.transport.gestures.record(press: true)
        clock.now += AgentPaneUserGestures.answerWindow + 0.5
        #expect(model.transport.gestures.isAvailable, "setup: the generic credit should still hold")
        #expect(!(await setUp()), "a deferred request spent an old key press")
        // A click from just now whose grant another frame spent opens nothing.
        model.transport.gestures.record(click: true, press: true)
        #expect(model.transport.gestures.consume())
        #expect(!(await setUp()), "a spent click opened Set Up")
        #expect(ran == ["palette.computerUse.setup"])
        // The Settings card's other Computer Use actions stay out of the pane's reach.
        for id in ["palette.computerUse.restart", "palette.computerUse.accessibility", "computerUse.approval.set"] {
            model.transport.gestures.record()
            #expect(await model.respond(to: .runAction(id))["ok"] as? Bool != true, "\(id)")
        }
        #expect(ran == ["palette.computerUse.setup"])
    }

    /// Review round 3 of #48024 (bind setup to the initiating physical event): Set Up takes only a Return press or a
    /// mouse click, and only while it is the pane's last input. Another key, a native choice or posted input after it
    /// ends it; a later click is a gesture of its own.
    @Test func setUpTakesOnlyTheLastReturnOrClick() async {
        final class Clock { var now: TimeInterval = 100 }
        let clock = Clock()
        let model = AgentPaneModel(host: NoHost(), transport: AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now })))
        var ran = 0
        model.onRunAction = { _, _ in ran += 1; return .ran }
        let gestures = model.transport.gestures
        let setUp = { await model.respond(to: .runAction(AgentPaneComputerUseState.setupAction))["ok"] as? Bool == true }
        // Another key (a letter, Space, Tab): no Set Up.
        gestures.record()
        #expect(!(await setUp()), "a key that is not Return opened Set Up")
        // Return, then another key before the request: the Return is no longer the person's last input.
        gestures.record(press: true)
        gestures.record()
        #expect(!(await setUp()), "a key typed after the Return let Set Up through")
        // Return, then input another process posted on the page.
        gestures.record(press: true)
        gestures.pageInput()
        #expect(!(await setUp()), "posted input after the Return let Set Up through")
        // Return, then a click: the click is the last input, and it opens Set Up once.
        gestures.record(press: true)
        gestures.pageInput()
        gestures.record(click: true, press: true)
        #expect(await setUp())
        #expect(!(await setUp()))
        #expect(ran == 1)
    }

    /// Review round 3 of #48024 (P1): a native New Tab page on an SSH or Cloud machine starts its chat there, so this
    /// Mac's Computer Use Setup neither holds nor opens for it; the page's first frame says so (`startsRemote`).
    @Test func aNewTabPageOnAnotherMachineNeitherHoldsForNorSaysThisMacsSetup() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var runs = 0
        let bound = registry.bind(ActionID(rawValue: AgentPaneComputerUseState.setupAction), invoke: { _ in runs += 1 })
        #expect(bound)
        let follower = AgentPaneComputerUse(read: nil)
        follower.set(.needsSetup)
        #expect(!follower.holdsSubmit("open Notes with @computer-use", startsRemote: true, registry: registry, refusal: "off"))
        #expect(runs == 0, "a remote page opened this Mac's setup")
        #expect(follower.holdsSubmit("open Notes with @computer-use", registry: registry, refusal: "off"))

        let remote = AgentPaneNewTab(kind: .agent).warmedOnThisMac(false)
        let local = AgentPaneNewTab(kind: .agent).warmedOnThisMac()
        #expect(remote.startsRemote == true && local.startsRemote == nil)
        // The field reaches the page's initial render: the page's own part of the context.
        #expect(remote.ownTree?["startsRemote"] as? Bool == true)
        #expect(local.ownTree?["startsRemote"] == nil)
    }

    /// Review round 3 of #48024 (task: acpmux holds `@computer-use` prompts): the host tells its local connection's acpmux
    /// the state as `_acpmux/computer_use_state {state}`, null while unknown.
    @Test func theDaemonHearsTheStateAsItsRawValueOrNull() throws {
        func params(_ state: AgentPaneComputerUseState?) throws -> [String: Any] {
            let text = try #require(AgentPaneTransport.computerUseStateFrame(state, id: 7))
            let frame = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(frame["method"] as? String == "_acpmux/computer_use_state")
            #expect(frame["id"] as? Int == 7)
            return try #require(frame["params"] as? [String: Any])
        }
        #expect(try params(.needsSetup)["state"] as? String == "needs_setup")
        #expect(try params(.ready)["state"] as? String == "ready")
        #expect(try params(.disabled)["state"] as? String == "disabled")
        #expect(try params(nil)["state"] is NSNull)
    }

    /// Review round 2 of #48024 (P0): New Tab's `app.action` runs a listed palette row as the person's pick with no
    /// gesture. No Computer Use action is listed for a page or run from one, even when a page names it.
    @Test func aNewTabPageNeitherListsNorRunsAComputerUseAction() async {
        // Review round 3 (P0): cmux Remote's own grant rows reach the same OS permission request; no substring names them.
        let computerUse = ["palette.computerUse.setup", "palette.computerUse.restart", "palette.computerUse.accessibility",
                           "palette.computerUse.screenRecording", "computerUse.approval.set", "computerUse.approval.forget",
                           "computerUseStop", "computerUseFocus", "remote.restartComputerUse",
                           "remote.allowAccessibility", "remote.allowScreenRecording", "remote.restartScreenSharing",
                           "macScreen.shareThisMac", "macScreen.deviceAccess"]
        for id in computerUse { #expect(!AgentPaneOmnibar.Action.pageMayRun(id), "\(id)") }
        #expect(AgentPaneOmnibar.Action.pageMayRun("newTab.page"))
        let listed = (computerUse + ["newTab.page"]).map { AgentPaneOmnibar.Action(id: $0, title: $0) }
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent, omnibar: AgentPaneOmnibar(actions: listed)))
        var ran: [String] = []
        model.onAppAction = { id, _ in ran.append(id) }
        for action in listed {
            let ok = await model.respond(to: .appAction(action.id))["ok"] as? Bool == true
            #expect(ok == (action.id == "newTab.page"), "\(action.id)")
        }
        #expect(ran == ["newTab.page"])
    }

    /// Review round 3 of #48024 (P0): the page-run rule is an explicit list, so a new action of Computer Use or cmux Remote
    /// fails here until someone classifies it: person-only (``AgentPaneOmnibar/Action/personOnly``) or page-safe below.
    @Test func everyComputerUseAndRemoteControlActionIsClassifiedForPages() {
        // Reviewed: these neither grant, turn control on, restart a helper, edit approvals nor drive a session.
        let pageSafe: Set<String> = ["remote.showStatus", "remote.setQuality", "remote.stopScreenSession", "machine.viewScreen",
                                     "macScreen.stopSharingThisMac"]
        let groups = ["CmuxRemoteActionCatalog", "ComputerUseApprovalActionCatalog"]
        let ids = groups.flatMap { ActionCatalog.descriptors(inGroup: $0) }.map(\.id.rawValue)
            + ActionCatalog.all.filter { ActionFeature.feature(of: $0) == .computerUse }.map(\.id.rawValue)
        #expect(ids.contains("remote.allowAccessibility") && ids.contains("palette.computerUse.setup"), "setup: the catalog groups moved")
        for id in Set(ids) {
            let personOnly = AgentPaneOmnibar.Action.personOnly[id] != nil
            #expect(personOnly != pageSafe.contains(id), "\(id): classify it as person-only or page-safe")
            #expect(AgentPaneOmnibar.Action.pageMayRun(id) == !personOnly, "\(id)")
        }
        // Every person-only id is a real catalog action: a renamed one is not left unguarded under its new id.
        let catalog = Set(ActionCatalog.all.map(\.id.rawValue))
        for id in AgentPaneOmnibar.Action.personOnly.keys { #expect(catalog.contains(id), "\(id) is no catalog action") }
    }

    @Test func aPromptNamesComputerUseOnlyAsAWholeWordOutsideCode() {
        for text in ["open the app with @computer-use", "@Computer-Use please", "open it with $computer-use", "Use (@computer-use) for this",
                     "use **@computer-use** now", "use @computer-use. Then stop", "\u{FFFC}shot-1\u{FFFC}@computer-use", "> quoted: @computer-use"] {
            #expect(AgentPaneComputerUseState.isNamed(in: text), "\(text)")
        }
        for text in ["run `@computer-use` literally", "```\n@computer-use\n```", "run `` a `@computer-use` b `` now", "mail me@computer-use.dev",
                     "@computer-user", "see @computer-use_notes", "review @computer-use.md", "@browser-use only", "costs $5", "no tools here", ""] {
            #expect(!AgentPaneComputerUseState.isNamed(in: text), "\(text)")
        }
    }

    /// Review round 2 of #48024: native New Tab opened the chat and closed, so the new chat's page held the send with
    /// no gesture left to open Set Up. The submit decides first, on the person's own key press.
    @Test func aNativeNewTabSubmitNamingComputerUseHoldsUntilItIsReady() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var runs: [ActionInvocation] = []
        let bound = registry.bind(ActionID(rawValue: AgentPaneComputerUseState.setupAction), invoke: { runs.append($0) })
        #expect(bound)
        var refusals: [String] = []
        registry.refusalObserver = { reason, _ in refusals.append(reason) }
        let follower = AgentPaneComputerUse(read: nil)
        let prompt = "open Notes with @computer-use"
        let holds = { follower.holdsSubmit(prompt, registry: registry, refusal: "turned off") }
        #expect(!holds(), "an unknown state let the page decide")
        follower.set(.ready)
        #expect(!holds(), "ready held the send")
        for state: AgentPaneComputerUseState in [.needsSetup, .starting, .unavailable] {
            follower.set(state)
            #expect(holds(), "\(state)")
        }
        #expect(runs.count == 3, "Set Up ran \(runs.count) times for 3 held submits")
        #expect(runs.allSatisfy { $0.origin == .user }, "Set Up did not run as the person's own run")
        #expect(!follower.holdsSubmit("open Notes", registry: registry, refusal: "turned off"), "a prompt with no mention was held")
        follower.set(.disabled)
        #expect(holds())
        #expect(refusals == ["turned off"])
        #expect(runs.count == 3, "Set Up ran while the organization turned computer use off")
    }
}
