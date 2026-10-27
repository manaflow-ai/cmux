#if os(iOS) && DEBUG
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import QuartzCore
import SwiftUI
import UIKit
import OSLog

private let demoLog = Logger(subsystem: "dev.cmux.mobile", category: "demo")

/// DEBUG-only scripted choreography for simulator recordings (`-cmux-mobile-demo <name>`).
/// Drawer drags feed synthetic finger positions, one per display frame, into
/// the container's real tracking path (`beginTracking` / `track` /
/// `endTracking`), so the recorded motion is the production pan code minus the
/// recognizer. The pauses below pace the recording; they are not synchronization.
@MainActor
struct DemoDriver {
    let shell: ShellModel

    /// The demos `run(_:)` knows.
    nonisolated static let names: Set<String> = ["drawer", "settings", "settings-bottom", "settings-middle", "states", "editor", "rubber", "workspaces", "workspaces-reopen", "chief", "chief-parity", "chief-open", "chief-cards", "chief-settings", "live", "workspace-new", "connect-mac", "connect-mac-elsewhere", "relay-only", "approve", "kbd-chat", "kbd-tab", "kbd-new", "kbd-feed", "kbd-empty", "kbd-chat-empty"]

    func run(_ name: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        switch name {
        case "drawer": await drawer()
        case "settings": await settings()
        case "settings-bottom": await settingsScrolled(to: "bottom")
        case "settings-middle": await settingsScrolled(to: "appearance")
        case "states": await states()
        case "editor": await editor()
        case "rubber": await rubber()
        case "workspaces": await workspaces()
        case "workspaces-reopen": await workspacesReopen()
        case "chief": await chief()
        case "chief-parity": await chiefParity()
        case "chief-settings": await chiefSettings()
        case "chief-cards": await chiefCards()
        case "chief-open":
            // Opens Chief and leaves it to real touches (verify/imsg-parity.sh).
            shell.tab = .home
            shell.homePath.append(ChiefRoute())
        case "ws-terminal": await workspaceTerminal()
        case "ws-terminal-card": await workspaceTerminalCard()
        case "tour-a": await tourHomeAndWorkspaces()
        case "tour-b": await tourFeedChatDiff()
        case "tour-c": await tourSettingsAndSidebar()
        case "onboarding": break  // driven by CmuxMobileOnboarding's script until the shell appears
        case "live": await live()
        case "approve": await approve()
        case "workspace-new": await workspaceNew()
        case "connect-mac": await connectMac()
        case "connect-mac-elsewhere": await connectMacElsewhere()
        case "relay-only": await relayOnly()
        // Keyboard verification (verify/keyboard.md): open a screen and leave
        // it to real touches.
        case "kbd-chat":
            shell.tab = .home
            shell.homePath.append(AgentChatDestination(workspaceID: "ws-cmux", tabID: "t-claude"))
        case "kbd-tab":
            shell.store.noteOpened(tabID: "t-claude", in: "ws-cmux")
            shell.tab = .workspaces
            await pause(1.0)
            if let ws = shell.store.workspace(id: "ws-cmux") { shell.workspacesPath = [ws] }
        case "kbd-new":
            shell.tab = .workspaces
            if let ws = shell.creator.create(start: .agent("claude")) { shell.workspacesPath.append(ws) }
        case "kbd-empty", "kbd-chat-empty":
            // A session with no turns (the empty state), as a new workspace
            // shows before its first prompt.
            AgentSessionDirectory.shared.makeSource = { summary in
                MockAgentSession(summary: summary, richFirstTurn: summary.harness == "claude", history: false)
            }
            if name == "kbd-empty" {
                shell.tab = .workspaces
                await pause(1.0)
                if let ws = shell.creator.create(start: .agent("claude")) { shell.workspacesPath.append(ws) }
            } else {
                shell.tab = .home
                shell.homePath.append(AgentChatDestination(workspaceID: "ws-cmux", tabID: "t-claude"))
            }
        case "kbd-feed":
            shell.tab = .feed
        default: break
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A finger drag of `distance` points over `duration`, released with the
    /// finger's last-frame velocity (or `release`). Slow drags ease in and out;
    /// flicks accelerate and lift off while still moving, like a real swipe.
    private func drag(_ distance: CGFloat, duration: Double, release: CGFloat? = nil, flick: Bool = false) async {
        let sidebar = shell.sidebar
        sidebar.beginTracking()
        let frames = FrameClock()
        let start = await frames.next()
        var last: (t: Double, x: CGFloat) = (0, 0)
        var velocity: CGFloat = 0
        while true {
            let t = min((await frames.next() - start) / duration, 1)
            let x = flick ? distance * CGFloat(t * t) : distance * CGFloat(t * t * (3 - 2 * t))
            let elapsed = t * duration
            if elapsed > last.t { velocity = (x - last.x) / CGFloat(elapsed - last.t) }
            last = (elapsed, x)
            sidebar.track(translationX: x)
            if t >= 1 { break }
        }
        frames.stop()
        sidebar.endTracking(velocityX: release ?? velocity)
    }

    private func drawer() async {
        // Slow interactive open, released past the threshold with little velocity.
        await drag(240, duration: 0.7, release: 120)
        await pause(1.6)
        // Fast flick closed.
        await drag(-110, duration: 0.12, flick: true)
        await pause(1.2)
        // Toolbar button open.
        shell.sidebar.open()
        await pause(1.4)
        // Switch team: highlight moves, drawer closes, content crossfades.
        if let next = shell.store.teams.first(where: { $0.id != shell.store.activeTeamID }) {
            shell.switchTeam(to: next.id)
        }
        await pause(1.6)
        // Partial drag that does not reach the threshold springs back closed.
        await drag(90, duration: 0.5, release: 0)
        await pause(1.2)
        // Open on a fast short flick (velocity wins over distance).
        await drag(70, duration: 0.1, flick: true)
        await pause(1.4)
        // Close by tapping the card.
        shell.sidebar.close()
        await pause(1.2)
    }

    /// Live link with the default dial, then Settings → Transport → Relay
    /// only (Developer) switched on (as a tap would, through the same `UserDefaults` key
    /// the toggle is bound to), then back to Workspaces, where the Mac's
    /// status line shows the TURN or relay path.
    private func relayOnly() async {
        UserDefaults.standard.set(false, forKey: DeveloperOptions.relayOnlyKey)
        shell.tab = .workspaces
        await pause(14)
        demoLog.info("demo: settings developer")
        shell.tab = .settings
        await pause(1.0)
        shell.settingsPath = [.transport]
        await pause(2.0)
        demoLog.info("demo: relay only on")
        UserDefaults.standard.set(true, forKey: DeveloperOptions.relayOnlyKey)
        await pause(3.0)
        shell.tab = .workspaces
        demoLog.info("demo: workspaces")
    }

    private func rubber() async {
        shell.sidebar.open()
        await pause(1.0)
        await drag(150, duration: 0.6, release: 0)
        await pause(1.2)
        shell.sidebar.close()
        await pause(1.0)
    }

    private func settings() async {
        shell.tab = .settings
        await pause(1.5)
        shell.settingsScrollTarget = "bottom"
        await pause(2.0)
        shell.settingsPath = [.devices]
        await pause(1.5)
        shell.settingsPath = []
        await pause(1.0)
        shell.settingsScrollTarget = "top"
        await pause(1.5)
    }

    /// Settings scrolled to `target` ("bottom" or a section id) and left
    /// there, for still captures.
    private func settingsScrolled(to target: String) async {
        shell.tab = .settings
        await pause(0.8)
        shell.settingsScrollTarget = target
    }

    private func states() async {
        shell.tab = .workspaces
        await pause(1.0)
        shell.store.teamDataState = .loading
        await pause(2.0)
        shell.store.teamDataState = .failed
        await pause(2.0)
        shell.store.teamDataState = .loaded
        await pause(1.0)
        shell.store.isOffline = true
        await pause(2.0)
        shell.store.isOffline = false
        await pause(0.8)
        if let index = shell.store.teams.firstIndex(where: { $0.id == shell.store.activeTeamID }) {
            let macs = shell.store.teams[index].macs
            shell.store.teams[index].macs = macs.map { mac in
                var offline = mac
                offline.isOnline = false
                return offline
            }
            await pause(2.0)
            shell.store.teams[index].macs = []
            await pause(2.0)
            shell.store.teams[index].macs = macs
        }
        await pause(1.0)
        shell.toast = CmuxMobileToast(symbol: "checkmark", text: "Paired with cmux mini 2")
        await pause(2.0)
    }

    /// Open a workspace on its last tab, chat, switch tabs through the grid
    /// (zoom out, zoom into a card), leave, and reopen on the new last tab.
    private func workspaces() async {
        let store = shell.store
        let tabs = WorkspaceDemoDirector.shared
        store.noteOpened(tabID: "t-claude", in: "ws-cmux")
        shell.tab = .workspaces
        await pause(1.6)
        guard let ws = store.workspace(id: "ws-cmux") else { return }
        shell.workspacesPath = [ws]
        await pause(2.4)
        DemoDirector.shared.post(.chatSend("Summarize what changed in the transport layer"))
        await pause(7.0)
        tabs.post(.showGrid(true))
        await pause(2.2)
        tabs.post(.activate("t-zsh"))
        await pause(2.2)
        tabs.post(.showGrid(true))
        await pause(2.0)
        tabs.post(.activate("t-docs"))
        await pause(3.5)
        tabs.post(.showGrid(true))
        await pause(1.8)
        tabs.post(.showGrid(false))
        await pause(1.8)
        tabs.post(.exit)
        await pause(1.8)
        // Reopen: starts on the browser tab used last.
        shell.workspacesPath = [ws]
        await pause(2.6)
        tabs.post(.exit)
        await pause(1.5)
    }

    /// New workspace: tap (instant create and push), hold (the menu of other
    /// starts), pick one, then a refusal (the pushed screen pops, a toast).
    /// Taps and holds go to the real toolbar control: `sendActions` for the
    /// tap, the context menu interaction for the hold.
    private func workspaceNew() async {
        shell.tab = .workspaces
        await pause(1.8)
        step("tap")
        tapNewWorkspace()
        await pause(1.2)
        step("pushed \(shell.workspacesPath.last?.title ?? "-")")
        await pause(2.4)
        WorkspaceDemoDirector.shared.post(.exit)
        await pause(1.6)
        step("hold")
        let menu = holdNewWorkspace()
        await pause(3.2)
        menu?.dismissMenu()
        await pause(0.5)
        step("pick claude")
        if let ws = shell.creator.create(start: .agent("claude")) { shell.workspacesPath.append(ws) }
        await pause(3.2)
        WorkspaceDemoDirector.shared.post(.exit)
        await pause(1.4)
        step("hold again")
        let again = holdNewWorkspace()
        await pause(2.4)
        again?.dismissMenu()
        await pause(0.5)
        step("refused")
        shell.mockCreation.failNext = "The Mac refused"
        tapNewWorkspace()
        await pause(3.5)
    }

    /// No Mac: the Connect your Mac state, then the Mac appears (presence).
    private func connectMac() async {
        shell.tab = .workspaces
        guard let index = shell.store.teams.firstIndex(where: { $0.id == shell.store.activeTeamID }) else { return }
        let macs = shell.store.teams[index].macs
        shell.store.teams[index].macs = []
        await pause(5.0)
        step("mac appears")
        shell.store.teams[index].macs = macs
        await pause(2.5)
    }

    /// The active team has no Mac, another team has one: the empty state
    /// names the team shown and offers the other; the switch runs the
    /// button's own action.
    private func connectMacElsewhere() async {
        shell.tab = .workspaces
        guard let index = shell.store.teams.firstIndex(where: { $0.id == shell.store.activeTeamID }) else { return }
        shell.store.teams[index].macs = []
        await pause(3.5)
        guard let offer = shell.store.teamWithMacsElsewhere() else { return }
        step("switch to \(offer.team.name)")
        shell.switchTeam(to: offer.team.id)
        await pause(3.0)
    }

    /// The toolbar's New Workspace bar button view: the visible navigation
    /// bar's trailing item that has both a primary action and a menu.
    private func newWorkspaceControl() -> UIView? {
        func bars(_ view: UIView) -> [UINavigationBar] {
            (view as? UINavigationBar).map { [$0] } ?? view.subviews.flatMap(bars)
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for bar in windows.flatMap(bars) where bar.window != nil && !bar.isHidden {
            let items = (bar.topItem?.trailingItemGroups.flatMap(\.barButtonItems) ?? []) + (bar.topItem?.rightBarButtonItems ?? [])
            if let item = items.first(where: { $0.accessibilityLabel == "New Workspace" || $0.title == "New Workspace" })
                ?? items.first(where: { $0.menu != nil && $0.primaryAction != nil }),
               let view = item.value(forKey: "view") as? UIView {
                return view
            }
        }
        return nil
    }

    private func menuInteraction(_ view: UIView) -> UIContextMenuInteraction? {
        if let found = view.interactions.lazy.compactMap({ $0 as? UIContextMenuInteraction }).first { return found }
        for sub in view.subviews { if let found = menuInteraction(sub) { return found } }
        return nil
    }

    private func tapNewWorkspace() {
        let before = shell.workspacesPath.count
        if let control = newWorkspaceControl() as? UIControl {
            step("control \(type(of: control))")
            control.sendActions(for: .primaryActionTriggered)
            if shell.workspacesPath.count == before { control.sendActions(for: .touchUpInside) }
        }
        if shell.workspacesPath.count == before, let ws = shell.creator.create() {
            step("tap fallback")
            shell.workspacesPath.append(ws)
        }
    }

    /// Presents the control's menu as a long press does (DEBUG only: the
    /// interaction's private present-at-location entry point).
    private func holdNewWorkspace() -> UIContextMenuInteraction? {
        guard let control = newWorkspaceControl(), let interaction = menuInteraction(control) else {
            step("hold: no menu interaction")
            return nil
        }
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: selector) else {
            step("hold: no present entry point")
            return nil
        }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(interaction.method(for: selector), to: Present.self)
        present(interaction, selector, CGPoint(x: control.bounds.midX, y: control.bounds.midY))
        return interaction
    }

    /// Waits (polling each 0.25 s) for `condition`, up to `timeout` seconds.
    @discardableResult
    private func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            await pause(0.25)
        }
        return true
    }

    /// Phone approvals end to end (verify/phone-approvals.md): waits for the link and
    /// the Mac's pairing, then works through the plan in the `cmuxMobile.demo.approve` default
    /// (comma separated; default `allow,allow,allow`). Each `allow` or `deny` answers the
    /// next ask that reaches the Feed through the card's own path: Allow (Face ID signs
    /// it) or the reject option for a permission, the first option (signed) or Decline
    /// for a question. `signout` signs out as Settings does (the phone asks the Mac to
    /// forget it).
    private func approve() async {
        step("start")
        shell.tab = .feed
        guard await until(120, { shell.live?.link.phase.isConnected == true }) else { return step("no link") }
        guard await until(180, { shell.live?.pairingState == .paired }) else {
            return step("not paired: \(String(describing: shell.live?.pairingState))")
        }
        step("paired")
        let feed = FeedStore.shared
        var answered: Set<String> = []
        let open = { feed.items.first { $0.needsYou && !answered.contains($0.id) } }
        let plan = (UserDefaults.standard.string(forKey: "cmuxMobile.demo.approve") ?? "allow,allow,allow")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for action in plan {
            if action == "signout" {
                step("sign out")
                await shell.auth.signOut()
                step("signed out")
                continue
            }
            guard await until(600, { open() != nil }), let item = open() else { return step("no more asks") }
            answered.insert(item.id)
            await pause(1.5)
            let allow = action != "deny"
            switch item.kind {
            case .permission(let request):
                let option = allow
                    ? request.options.first(where: { $0.kind == .allowOnce }) ?? request.options.first(where: \.isAllow)
                    : request.options.first(where: { $0.kind == .rejectOnce }) ?? request.options.first(where: { !$0.isAllow })
                guard let option else { continue }
                step("feed \(allow ? "allow" : "deny") \(item.id)")
                feed.respond(item.id, option: option)
            case .question(let question):
                if !allow {
                    step("feed decline \(item.id)")
                    feed.decline(item.id)
                    break
                }
                guard let first = question.items.first, let option = first.options.first else { continue }
                step("feed answer \(item.id)")
                feed.answer(item.id, answer: AgentQuestionAnswer(selections: [first.id: .init(optionIDs: [option.id])]))
            default:
                continue
            }
            await until(90) { feed.items.first { $0.id == item.id }.map { !$0.needsYou || $0.error != nil } ?? true }
            let after = feed.items.first { $0.id == item.id }
            step("result \(item.id): resolution=\(after?.resolution ?? "-") error=\(after?.error ?? "-")")
        }
        step("plan done")
    }

    /// Live end to end (real Mac): Mac online and connected, the daemon's
    /// workspaces, an agent tab streaming acpmux, Feed answers sent back,
    /// then a WebRTC ↔ WireGuard switch.
    private func live() async {
        step("start")
        shell.tab = .workspaces
        guard await until(60, { shell.live?.link.phase.isConnected == true }) else { return }
        guard await until(30, { !shell.store.workspaces.isEmpty }) else { return }
        await pause(2.5)
        // The sidebar: the personal space as "Personal" with its live Mac dots.
        step("sidebar")
        shell.sidebar.open()
        await pause(3)
        shell.sidebar.close()
        await pause(1.5)
        // Open the workspace that has an agent tab, on that tab.
        guard let ws = shell.store.workspaces.first(where: { $0.tabs.contains { $0.kind == .agent } }),
              let agent = ws.tabs.first(where: { $0.kind == .agent }) else { return }
        shell.store.noteOpened(tabID: agent.id, in: ws.id)
        step("open workspace \(ws.title) on \(agent.title)")
        shell.workspacesPath = [ws]
        await pause(4)
        let mac = shell.store.activeTeam?.macs.first { $0.id == ws.macID }?.name ?? "Mac"
        let chat = AgentSessionDirectory.shared.store(workspace: ws, tab: agent, macName: mac)
        chat.send(prompt: "What does the README say?")
        await pause(5)
        step("prompt ask")
        chat.send(prompt: "ask: rm -rf build")
        await until(15) { chat.pendingPermission != nil }
        await pause(2.5)
        // Answer from the Feed: Allow (refused for a phone), then Deny (reaches the Mac).
        shell.workspacesPath = []
        await pause(1)
        step("feed")
        shell.tab = .feed
        await pause(3)
        let feed = FeedStore.shared
        await until(10) { feed.items.contains { if case .permission = $0.kind { return $0.needsYou }; return false } }
        if let item = feed.items.first(where: { if case .permission = $0.kind { return $0.needsYou }; return false }),
           case .permission(let request) = item.kind {
            step("feed allow \(item.id)")
            if let allow = request.options.first(where: \.isAllow) { feed.respond(item.id, option: allow) }
            await pause(3.5)
            step("feed deny \(item.id)")
            if let deny = request.options.first(where: { !$0.isAllow }) { feed.respond(item.id, option: deny) }
            await pause(3)
        }
        // A question: answered from the Feed.
        step("prompt question")
        chat.send(prompt: "question: Which approach?")
        await until(15) { feed.items.contains { if case .question = $0.kind { return $0.needsYou }; return false } }
        await pause(2.5)
        if let item = feed.items.first(where: { if case .question = $0.kind { return $0.needsYou }; return false }),
           case .question(let question) = item.kind, let first = question.items.first, let option = first.options.first {
            step("feed answer \(item.id)")
            feed.answer(item.id, answer: AgentQuestionAnswer(selections: [first.id: .init(optionIDs: [option.id])]))
            await pause(3.5)
        }
        // Transport switch: WebRTC (no TURN: fails gracefully), then back to WireGuard.
        shell.tab = .workspaces
        await pause(2)
        step("transport webrtc")
        shell.settings.transport = .webrtc
        await until(45) { if case .waiting = shell.live?.link.phase { return true }; return false }
        await pause(4)
        step("transport wireguard")
        shell.settings.transport = .wireguard
        await until(30) { shell.live?.link.phase.isConnected == true }
        await pause(4)
    }

    private func step(_ name: String) {
        demoLog.info("demo step: \(name, privacy: .public)")
    }

    /// After a relaunch: the workspace opens on the tab used last before it.
    private func workspacesReopen() async {
        shell.tab = .workspaces
        await pause(1.6)
        guard let ws = shell.store.workspace(id: "ws-cmux") else { return }
        shell.workspacesPath = [ws]
        await pause(3.0)
        WorkspaceDemoDirector.shared.post(.showGrid(true))
        await pause(2.2)
        WorkspaceDemoDirector.shared.post(.showGrid(false))
        await pause(2.0)
    }

    /// Home list, open Chief, send (receipt, Chief's tapback, typing, reply),
    /// tapback Chief's reply, send again, scroll, back to the list.
    private func chief() async {
        let hook = ChiefDemoHook.shared
        shell.tab = .home
        await pause(2.4)
        shell.homePath.append(ChiefRoute())
        await pause(2.6)
        hook.lab("send thanks! what's the status?")
        await pause(6.5)
        // The tapback bar has no lab verb upstream; react through the store.
        hook.react("thumbsup")
        await pause(2.2)
        hook.lab("send yes, allow it")
        await pause(6.5)
        hook.scroll(toTop: true)
        await pause(2.2)
        hook.scroll(toTop: false)
        await pause(1.8)
        if !shell.homePath.isEmpty { shell.homePath.removeLast() }
        await pause(2.5)
    }

    /// Chief's cards (https://github.com/manaflow-ai/cmux/issues/25830) on the
    /// mock Chief: a live browser card that moves to its next step, a reply
    /// with a next-step chip and a Secure Store card, left for real touches
    /// (tap the chip, Open browser, Add).
    private func chiefCards() async {
        let hook = ChiefDemoHook.shared
        shell.tab = .home
        await pause(1.6)
        shell.homePath.append(ChiefRoute())
        await pause(2.0)
        guard let mock = ChiefSession.shared.backend as? ChiefMockBackend else {
            mark("chief-cards needs the mock Chief")
            return
        }
        await mock.postCardsDemo()
        await pause(1.0)
        hook.scroll(toTop: false)
        await pause(3.0)
        mark("chief-cards shown")
    }

    /// Chief parity (verify/chief-parity.md): Home without a title; New
    /// Message to an agent (opens its chat), then to Chief (opens the Chief
    /// conversation over the already-connected shared store, which used to
    /// leave the header empty); the send-time drawer through its own pan
    /// steps, held, then released; a photo send; the Photos drawer; back.
    /// Chief's settings in place of contact details (verify/chief-mac-parity.md):
    /// opens Chief, its settings from the header, and flips Hide Alerts and
    /// Send Read Receipts on and off the way a tap changes them.
    private func chiefSettings() async {
        let hook = ChiefDemoHook.shared
        let session = ChiefSession.shared
        shell.tab = .home
        await pause(1.5)
        shell.homePath.append(ChiefRoute())
        await pause(2.0)
        mark("header taken over: \(hook.headerTakenOver)")
        hook.openSettings()
        await pause(1.5)
        for (label, change) in [("hide alerts on", { session.setMuted(true) }), ("hide alerts off", { session.setMuted(false) }),
                                ("receipts off", { session.setSendsReadReceipts(false) }), ("receipts on", { session.setSendsReadReceipts(true) })] {
            mark(label)
            withAnimation { change() }
            await pause(1.5)
        }
        mark("end")
    }

    private func chiefParity() async {
        let hook = ChiefDemoHook.shared
        shell.tab = .home
        mark("home")
        await pause(2.5)
        // Home's compose opens Chief with the keyboard up (SPEC 1.4).
        mark("compose chief")
        shell.homePath.append(ChiefRoute(focusesComposer: true))
        await pause(2.0)
        mark("compose chief send")
        hook.lab("send what's the status?")
        await pause(7.0)
        // The send-time drawer is swiped with real touches (verify/imsg-parity.sh).
        mark("photo")
        hook.attachPhoto(Self.samplePhoto())
        await pause(6.5)
        mark("photos drawer")
        hook.photoLab("drawer")
        await pause(3.0)
        hook.photoLab("close")
        await pause(2.0)
        mark("back")
        if !shell.homePath.isEmpty { shell.homePath.removeLast() }
        await pause(2.5)
        mark("end")
    }

    /// A 1200 x 900 test photo (a gradient and a grid), rendered on device.
    private static func samplePhoto() -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.35).setStroke()
            for x in stride(from: 0, through: size.width, by: 100) {
                context.cgContext.move(to: CGPoint(x: x, y: 0)); context.cgContext.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: 100) {
                context.cgContext.move(to: CGPoint(x: 0, y: y)); context.cgContext.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.cgContext.strokePath()
        }
    }

    /// Appends a wall-clock mark to `Documents/terminal-demo-timeline.txt`
    /// (the terminal verification scripts line these up with the recording).
    private func mark(_ label: String) {
        if label != "state", let model = shell.terminalTabs.model(forTabID: "t-zsh") { mark("state", model.debugState) }
        mark(label, nil)
    }

    private func mark(_ label: String, _ detail: String?) {
        let label = detail.map { "\(label) \($0)" } ?? label
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, label)
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("terminal-demo-timeline.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// The terminal tab inside a workspace (embedded chrome): composer and
    /// key bar riding the keyboard above TabsKit's toolbar, TUI mode pinned
    /// to the composer, the grid card snapshot, a tab switch away and back
    /// (scrollback kept), Files and Links from the page menu, and leaving.
    private func workspaceTerminal() async {
        let store = shell.store
        let tabs = WorkspaceDemoDirector.shared
        store.noteOpened(tabID: "t-zsh", in: "ws-cmux")
        shell.tab = .workspaces
        await pause(1.2)
        guard let ws = store.workspace(id: "ws-cmux") else { return }
        mark("open workspace")
        shell.workspacesPath = [ws]
        await pause(3.0)
        guard let model = shell.terminalTabs.model(forTabID: "t-zsh") else { return }
        mark("keyboard show (composer)")
        model.toggleKeyboard()
        await pause(1.8)
        mark("type")
        for character in "ls -la" {
            model.composerText.append(character)
            await pause(0.07)
        }
        await pause(0.5)
        mark("send")
        model.send()
        await pause(1.2)
        mark("keyboard hide")
        model.toggleKeyboard()
        await pause(1.8)
        mark("keyboard show")
        model.toggleKeyboard()
        await pause(1.8)
        mark("keyboard hide")
        model.toggleKeyboard()
        await pause(1.5)
        mark("run htop")
        model.composerText = "htop"
        model.send()
        await pause(2.5)
        mark("keyboard show (direct)")
        model.toggleKeyboard()
        await pause(2.2)
        mark("keyboard hide")
        model.toggleKeyboard()
        await pause(2.2)
        mark("keyboard show")
        model.toggleKeyboard()
        await pause(2.0)
        mark("keyboard hide")
        model.toggleKeyboard()
        await pause(1.8)
        mark("quit htop")
        model.composerText = "q"
        model.sendWithoutReturn()
        await pause(1.8)
        mark("grid")
        tabs.post(.showGrid(true))
        await pause(2.4)
        mark("agent tab")
        tabs.post(.activate("t-claude"))
        await pause(2.4)
        mark("grid")
        tabs.post(.showGrid(true))
        await pause(2.0)
        mark("terminal tab again")
        tabs.post(.activate("t-zsh"))
        await pause(2.4)
        mark("files and links")
        model.showFilesAndLinks()
        await pause(2.6)
        model.showArtifacts = false
        await pause(1.6)
        mark("exit")
        tabs.post(.exit)
        await pause(1.8)
        mark("end")
    }

    /// V5-6: a terminal page longer than its card, then the grid with that
    /// tab active: the card must show the newest rows (#0000400) and the
    /// prompt at its bottom edge, not the page's top.
    private func workspaceTerminalCard() async {
        let store = shell.store
        let tabs = WorkspaceDemoDirector.shared
        store.noteOpened(tabID: "t-zsh", in: "ws-cmux")
        shell.tab = .workspaces
        await pause(1.2)
        guard let ws = store.workspace(id: "ws-cmux") else { return }
        shell.workspacesPath = [ws]
        await pause(3.0)
        guard let model = shell.terminalTabs.model(forTabID: "t-zsh") else { return }
        model.composerText = "stream 400 2"
        model.send()
        await pause(3.0)
        mark("grid")
        tabs.post(.showGrid(true))
        await pause(8.0)
        mark("end")
    }

    // MARK: Full-app walkthrough (polish pass), in three recordings

    /// Home, Chief, back; Workspaces, a workspace on its last tab (agent),
    /// the grid, the terminal tab with the keyboard, the agent tab, leave.
    private func tourHomeAndWorkspaces() async {
        let store = shell.store
        let tabs = WorkspaceDemoDirector.shared
        store.noteOpened(tabID: "t-claude", in: "ws-cmux")
        mark("home")
        shell.tab = .home
        await pause(2.4)
        mark("chief")
        shell.homePath.append(ChiefRoute())
        await pause(2.4)
        mark("chief send")
        _ = ChiefDemoHook.shared.lab("send thanks! what's the status?")
        await pause(6.0)
        mark("home back")
        if !shell.homePath.isEmpty { shell.homePath.removeLast() }
        await pause(2.0)
        mark("workspaces")
        shell.tab = .workspaces
        await pause(2.0)
        guard let ws = store.workspace(id: "ws-cmux") else { return }
        mark("workspace (last tab: agent)")
        shell.workspacesPath = [ws]
        await pause(2.8)
        mark("grid")
        tabs.post(.showGrid(true))
        await pause(2.2)
        mark("terminal tab")
        tabs.post(.activate("t-zsh"))
        await pause(2.6)
        if let model = shell.terminalTabs.model(forTabID: "t-zsh") {
            mark("keyboard show")
            model.toggleKeyboard()
            await pause(1.6)
            for character in "git status" {
                model.composerText.append(character)
                await pause(0.07)
            }
            await pause(0.4)
            mark("send")
            model.send()
            await pause(1.4)
            mark("keyboard hide")
            model.toggleKeyboard()
            await pause(1.6)
        }
        mark("grid")
        tabs.post(.showGrid(true))
        await pause(2.0)
        mark("agent tab")
        tabs.post(.activate("t-claude"))
        await pause(2.4)
        mark("exit")
        tabs.post(.exit)
        await pause(2.0)
        mark("end")
    }

    /// Feed: scroll, Show more, answer a question inline, open an event in
    /// its agent chat, a streamed turn (permission and question answered),
    /// the diff viewer (file, Split and back), the Changes list.
    private func tourFeedChatDiff() async {
        let director = DemoDirector.shared
        func post(_ command: DemoDirector.Command, _ label: String, then seconds: Double) async {
            mark(label)
            director.post(command)
            await pause(seconds)
        }
        mark("feed")
        shell.tab = .feed
        await pause(2.4)
        await post(.feedScroll(toEvent: "f-long"), "scroll", then: 1.6)
        await post(.feedExpand(event: "f-long"), "show more", then: 2.2)
        await post(.feedScrollTop, "top", then: 1.6)
        await post(.answerQuestion(id: "feed-q-release", picks: [["rc"], ["transport", "feed", "diff"], ["yes"]]), "answer inline", then: 5.0)
        await post(.feedOpen(event: "f-finished"), "open event", then: 2.2)
        guard let chat = AgentSessionDirectory.shared.existingStore(id: "t-claude") else { return }
        if chat.pendingQuestion?.id == "q-waiting" {
            await post(.answerQuestion(id: "q-waiting", picks: [["webrtc"], ["connection"]]), "answer waiting", then: 0.5)
        }
        await waitFor(seconds: 30) { !chat.isRunning }
        await post(.chatSend("Make the transport layer switchable between WebRTC and WireGuard, and add tests"), "chat send", then: 3.0)
        await waitFor(seconds: 30) { chat.pendingPermission != nil }
        await pause(1.4)
        await post(.chatPermission(optionKind: "allow_once"), "allow once", then: 0.5)
        await waitFor(seconds: 30) { chat.pendingQuestion != nil }
        await pause(1.2)
        await post(.answerQuestion(id: "q-transport", picks: [["wireguard"], ["connection", "per-mac"]]), "answer question", then: 0.5)
        await waitFor(seconds: 40) { !chat.isRunning }
        await pause(1.6)
        await post(.chatOpenFirstFile, "diff file", then: 2.2)
        await post(.diffExpandFirst, "expand context", then: 1.4)
        await post(.diffSetSplit(true), "split", then: 2.2)
        await post(.diffSetSplit(false), "unified", then: 1.2)
        await post(.navigateBack, "back to chat", then: 1.4)
        await post(.chatOpenChanges, "changes list", then: 2.6)
        await post(.navigateBack, "back to chat", then: 1.6)
        mark("end")
    }

    /// Settings (transport switch), the sidebar (team switch), the team
    /// appearance editor (color and emoji).
    private func tourSettingsAndSidebar() async {
        mark("settings")
        shell.tab = .settings
        await pause(2.2)
        let original = shell.settings.transport
        mark("transport switch")
        shell.settings.transport = original == .webrtc ? .wireguard : .webrtc
        await pause(1.8)
        shell.settings.transport = original
        await pause(1.4)
        mark("sidebar")
        shell.sidebar.open()
        await pause(1.8)
        mark("team switch")
        if let next = shell.store.teams.first(where: { $0.id != shell.store.activeTeamID }) {
            shell.switchTeam(to: next.id)
        }
        await pause(2.0)
        mark("sidebar again")
        shell.sidebar.open()
        await pause(1.6)
        mark("editor")
        shell.editingTeam = shell.store.activeTeam
        await pause(2.0)
        let director = DemoDirector.shared
        mark("color")
        director.post(.editorColor(hex: CmuxMobileTheme.standard.colors.teamPalette.dropFirst(4).first?.dark ?? "#30D158"))
        await pause(1.4)
        mark("emoji")
        director.post(.editorEmoji("🚀"))
        await pause(1.4)
        mark("done")
        director.post(.editorDone)
        await pause(1.8)
        mark("close sidebar")
        shell.sidebar.close()
        await pause(1.6)
        mark("end")
    }

    /// Re-checks `condition` when observed state changes, up to a deadline.
    private func waitFor(seconds: Double, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }

    /// `-cmux-mobile-team-transparent` (layout captures): the first two
    /// teams that are not the personal space show an emoji and a letter with
    /// no background.
    func seedTransparentTeams() {
        let teams = shell.store.teams.filter { !$0.isPersonalSpace }
        for (team, glyph) in zip(teams, ["🚀", "Q"]) {
            var appearance = team.appearance
            appearance.glyph = .custom(glyph)
            appearance.isTransparent = true
            shell.store.setAppearance(appearance, for: team.id)
        }
    }

    private func editor() async {
        shell.sidebar.open()
        await pause(1.2)
        shell.editingTeam = shell.store.activeTeam
        await pause(3.0)
    }
}

/// Awaits display frames.
@MainActor
private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var waiter: CheckedContinuation<Double, Never>?

    func next() async -> Double {
        await withCheckedContinuation { continuation in
            waiter = continuation
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: link.targetTimestamp)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
#endif
