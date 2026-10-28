import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextPages
import CmuxNextTerminal
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextLaunch

// Typing into a screen before it can take keys (spec app-screens.md section
// 3, R59): the primary input of a screen that has one (R65), and the
// type-ahead queue of a page whose document has not focused its primary
// input yet (`PageInputReadiness`). Shortcuts resolve before either.
extension KeyRouter {
    /// A key that is not a chord, after every early owner passed it (or, in normal mode, none could take it): a page
    /// that owns bare keys, the type-ahead queue or the screen's primary input may take it, else it goes on to the
    /// focused view. Typing into a terminal reads only the first responder (the plain-typing path, KeyRouterBench).
    /// Returns whether the key was consumed.
    func typesIntoFocusedView(_ event: NSEvent, in window: NSWindow?) -> Bool { // perf-hot: 0.5ms key-dispatch (every typing key)
        if let window, !(window.firstResponder is TerminalSurfaceView) {
            if routesBareKey(event, in: window) { return true }
            if typesAhead(event, in: window) || typesIntoPrimaryInput(event, in: window) { return true }
        }
        onTyping?(window)
        return false
    }

    /// A key on a screen whose primary input claims it (R65; Home's message
    /// box: printable and dead keys, `PrimaryInputTarget.routesToPrimaryInput`)
    /// while none of the screen's text inputs has the keyboard: focus that
    /// input and give it the key. This is the one path for keys bound to a
    /// screen's primary input from anywhere in the screen. Typing in a
    /// terminal never looks up the window (typing-latency path).
    func typesIntoPrimaryInput(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView), event.type == .keyDown,
              !Self.isChord(event.modifierFlags) else { return false }
        guard let focused = focusedPrimaryInput(in: window), focused.input.routesToPrimaryInput(event) else { return false }
        let (focus, target) = (focused.focus, focused.input)
        let facts = Facts(hasMarkedText: (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true,
                          primaryInputReady: target.acceptsRedirectedTyping, primaryInputClaimsKey: true)
        guard decide(event, focus: focus, keyWindow: .content, facts: facts) == .primaryInput else { return false }
        decided.add(event)
        target.beginTyping(with: event)
        return true
    }

    /// The focused pane's primary input in `window`, a main window, with the
    /// focus it was resolved from; nil when the pane shows none.
    func focusedPrimaryInput(in window: NSWindow?) -> (focus: FocusState, input: any PrimaryInputTarget)? {
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return nil }
        let focus = controller.focus.state
        guard Self.mayHavePrimaryInput(focus.resolved), let pane = focus.resolved.pane,
              let target = controller.content?.paneController(key: pane)?.currentContent?.primaryInput else { return nil }
        return (focus: focus, input: target)
    }

    /// The target of a nil-targeted paste command in `window` instead of
    /// AppKit's `found` (``PrimaryInputPasteRoute``); nil keeps `found`.
    func pasteTarget(for action: Selector, found: AnyObject?, in window: NSWindow?) -> AnyObject? {
        guard PrimaryInputPasteRoute.actions.contains(action), let focused = focusedPrimaryInput(in: window) else { return nil }
        return PrimaryInputPasteRoute().target(for: action, found: found, in: window, input: focused.input)
    }

    /// Pages whose keys may wait for their document: agent pages (the new
    /// tab page, chats) and React pages (CmuxNextPages).
    nonisolated static func mayQueueTyping(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .agentPage, .page: true
        default: false
        }
    }

    /// A printable key on a page that cannot take typing yet: queue it for
    /// that page, in order; it goes to the page's focused primary input
    /// when the page reports it ready. Delete edits the queue; another key
    /// that is not typing ends the queue, so no key arrives out of order.
    func typesAhead(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !(window.firstResponder is TerminalSurfaceView) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content else { return false }
        let focus = controller.focus.state
        guard Self.mayQueueTyping(focus.resolved), let pane = focus.resolved.pane,
              let readiness = controller.content?.paneController(key: pane)?.currentContent?.inputReadiness else { return false }
        let surface = String(describing: ObjectIdentifier(readiness))
        let waiting = typeAhead.pending(for: surface) || deliveringTypeAhead == surface
        let facts = Facts(pageInputPending: !readiness.isReady || waiting)
        guard decide(event, focus: focus, keyWindow: kind, facts: facts) == .typeAhead else {
            guard waiting else { return false }
            if event.keyCode == Self.deleteKeyCode {
                // A Delete while the taken text is being inserted, with nothing queued after it, is
                // for that text: it goes to the page once the text landed (it was dropped before).
                typeAhead.deleteBackward(surface: surface, delivering: deliveringTypeAhead == surface)
                decided.add(event)
                return true
            }
            dropTypeAhead()
            return false
        }
        decided.add(event)
        typeAhead.append(event.characters ?? "", surface: surface, now: .now)
        typeAheadFocus = focus.resolved
        readiness.onReady = { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            flushTypeAhead(surface, into: readiness)
        }
        if readiness.isReady { flushTypeAhead(surface, into: readiness) }
        return true
    }

    nonisolated static let deleteKeyCode: UInt16 = 51

    /// Delivers the queued text, one insertion at a time; keys typed while
    /// one is delivered follow it. Deletes typed while it was on its way go
    /// right after it, before any text queued later.
    func flushTypeAhead(_ surface: String, into readiness: PageInputReadiness) {
        guard deliveringTypeAhead == nil, let text = typeAhead.take(surface: surface, now: .now) else { return }
        deliveringTypeAhead = surface
        let expectedEpoch = readiness.focusEpoch
        // task-owner: one queued insertion into the page, then its Deletes; the next flush runs after it
        Task { [weak self, weak readiness] in
            guard let self, let readiness else { return }
            guard await readiness.insert(text, expectedEpoch: expectedEpoch) else {
                // The original element disappeared or refused the insert; discard Deletes tied
                // to that failed text so they cannot hit a later focused field.
                self.typeAhead.takeDeletes()
                self.deliveringTypeAhead = nil
                return
            }
            // Ends when no Delete came in during the last edit; each pass sends what came before it.
            while self.typeAhead.pendingDeletes > 0 {
                // Consume this batch before awaiting the page so Deletes arriving during the
                // asynchronous edit remain queued for the next pass.
                let deletes = self.typeAhead.takeDeletes()
                let applied = await readiness.deleteBackward(deletes, expectedEpoch: expectedEpoch)
                if !applied {
                    self.typeAhead.takeDeletes()
                    break
                }
            }
            deliveringTypeAhead = nil
            flushTypeAhead(surface, into: readiness)
        }
    }

    /// A chord or another key ends the queue.
    func dropTypeAhead() {
        if deliveringTypeAhead == nil {
            typeAhead.drop()
        } else {
            // The taken text is still on its way to the page. Keep Deletes typed after it so a
            // chord/Return cannot clear edits that must follow that text.
            typeAhead.dropPendingText()
        }
        typeAheadFocus = nil
    }

    /// Focus moved off the page the keys wait for: they are dropped.
    func typeAheadFocusDidSettle(_ resolved: FocusState.Resolved) {
        guard let waiting = typeAheadFocus, waiting != resolved else { return }
        dropTypeAhead()
    }
}

// The key router's part in the launch picture phase (p08-startup-061): keys typed while a window shows its saved
// picture change only the model in their turn, no key builds the window, and none waits for the window or a terminal
// view to be built (each goes to its destination at once, and the destination queues it).
// - The window cannot decide a key yet (it has no controller, or its focus has not resolved): a typing key goes to the
//   terminal the window's saved session restores focus to, by id (`holdsUndecided`). A chord, or a key of a window
//   with no such terminal, waits whole and goes through the router again once the window can.
// - Otherwise the router decides it as usual: an action runs (a Command chord, a Control chord, a chord's leader or the
//   key after it), and only a key the dispatcher hands to the focused terminal, whose live view is not built, goes to
//   that terminal by id (`holdsForTerminal`), which raises the pane's build slice to the next frame.
// A key that reaches nothing is refused with the refusal notice, its text kept on it (`refuseKeys`).
// The router turns its `.launchPicture` mode on while the buffer is active and asks it only then.
extension LaunchPictureKeys {
    /// The buffer of `router`: it delivers to the router's terminal views, sends by id through the tab's daemon,
    /// replays through the router's dispatch, and refuses through its registry.
    static func routed(by router: KeyRouter) -> LaunchPictureKeys {
        let keys = LaunchPictureKeys { [weak router] target, events in
            router.map { deliverKeys(events, to: target, router: $0) } ?? false
        }
        keys.forward = { [weak router] target, events, answered in
            guard let router else { return answered(.keptForView(taken: 0)) }
            sendKeys(events, to: target, router: router, answered: answered)
        }
        keys.replay = { [weak router] window, events in router.map { replayKeys(events, window: window, router: $0) } ?? false }
        keys.refuse = { [weak router] window, text, reason in
            guard let router else { return }
            router.trace?("launch picture: keys of window \(window) reached nothing: \(reason ?? "no terminal could take them")")
            refuseKeys(text, reason: reason, window: window, router: router)
        }
        // Each wait is a measured launch stage: per reason, the sum of the waits and their key count, as launch values
        // (signpost and the startup bench's line; bench-startup.py's VALUE_MARKS), once when the picture phase ends.
        keys.onWaitTotals = { [weak router] totals in
            for total in totals {
                let ms = Double(total.waited.components.seconds) * 1000 + Double(total.waited.components.attoseconds) / 1e15
                router?.trace?("launch picture: \(total.keys) keys waited \(ms) ms: \(total.reason.rawValue)")
                LaunchMarkSink.shared.writeValue(name: "launch_picture_keys.wait_ms.\(total.reason.rawValue)", number: ms)
                LaunchMarkSink.shared.writeValue(name: "launch_picture_keys.keys.\(total.reason.rawValue)", number: Double(total.keys))
            }
        }
        keys.optionAsAlt = { GhosttyRuntime.shared.macosOptionAsAlt.flatMap(TypedTerminalInput.OptionAsAlt.init(config:)) }
        keys.selectsInputMethod = { GhosttyRuntime.shared.inputSources.selectsInputMethod }
        keys.onActiveChange = { [modes = router.modes] in modes.set(.launchPicture, $0) }
        return keys
    }

    /// Before every owner: whether `event` goes through here because `window`, showing its launch picture, cannot
    /// decide it yet, or keys typed there before it still wait to be decided (this one goes behind them). A typing
    /// key goes to the terminal the window restores focus to, by id; the rest wait to be decided.
    func holdsUndecided(_ event: NSEvent, in window: NSWindow?, router: KeyRouter) -> Bool {
        guard let window, let found = Self.pictureWindow(window, router: router, keys: self), holds(window: found.id) else { return false }
        if !isHoldingUndecided(window: found.id) {
            let decides = found.controller.map { Self.decidesKeys($0.focus.state.resolved) } ?? false
            guard showsPicture(window: found.id), !decides else { return false }
            // A chord waits whole: it may be one of the window's shortcuts, which only the window can decide.
            if !KeyRouter.isChord(event.modifierFlags), let target = Self.restoredTerminal(of: found.id, router: router) {
                router.decided.add(event)
                router.trace?("launch picture: the key goes to terminal \(target.tab), the window's restored focus")
                hold(event, for: target)
                return true
            }
        }
        router.trace?("launch picture: the key waits for its window to decide it")
        holdUndecided(event, window: found.id)
        return true
    }

    /// After the dispatcher handed `event` to the focused view: whether it goes through here for the focused
    /// terminal of `window`, still a picture (by id), or keys sent to it are still on their way (behind them). A
    /// terminal that is live and has the keyboard, with nothing on its way to it, takes its keys on the usual path.
    /// A Command chord no action took is the menu's or the terminal's key equivalent, never typing: it goes on as usual.
    func holdsForTerminal(_ event: NSEvent, in window: NSWindow?, router: KeyRouter) -> Bool {
        guard router.modes.contains(.launchPicture), let window, !event.modifierFlags.contains(.command) else { return false }
        let (controller, kind) = router.focus(for: window)
        guard let controller, kind == .content, case .terminal(let pane, let tab) = controller.focus.state.resolved else { return false }
        let target = Target(window: controller.state.id, pane: pane, tab: tab)
        guard holds(window: target.window) else { return false }
        let shell = controller.window ?? window
        if !isHolding(target), let live = Self.liveSurface(of: target, router: router), shell.firstResponder === live { return false }
        router.decided.add(event)
        router.trace?("launch picture: the key goes to terminal \(tab)")
        hold(event, for: target)
        return true
    }

    /// A focus the window decides keys for: not nothing yet, and not a pane whose content is not known.
    nonisolated static func decidesKeys(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .none, .emptyPane: false
        default: true
        }
    }

    /// The launch picture window `window` is: its id, and its controller once it has one (the picture can show
    /// before the controller is built). Nil for a panel, a popup or a window showing no picture.
    private static func pictureWindow(_ window: NSWindow, router: KeyRouter,
                                      keys: LaunchPictureKeys) -> (id: String, controller: WindowController?)? {
        let (controller, kind) = router.focus(for: window)
        if let controller { return kind == .content ? (controller.state.id, controller) : nil }
        guard let id = keys.window(showing: window) else { return nil }
        return (id, nil)
    }

    /// The terminal window `id` restores focus to from its saved session (`WindowState.adopt`): its shown
    /// workspace's saved focused pane and that pane's selected tab, when that is a terminal. Nil when the window
    /// shows a top page, saved no focus, or its focused pane shows something else.
    private static func restoredTerminal(of id: String, router: KeyRouter) -> Target? {
        guard let services = router.services, let state = services.windows.states[id], state.page == nil,
              let workspace = state.workspaceID, let paneID = state.savedFocusedPane,
              let pane = services.workspace(id: workspace)?.screens.flatMap(\.panes).first(where: { $0.id == paneID }) else { return nil }
        let selected = state.selection.selection(in: paneID).flatMap { tab in pane.tabs.first { $0.id == tab } }
        guard let tab = selected ?? (pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex] : nil),
              tab.kind == .pty || tab.kind == .remoteTerminal else { return nil }
        return Target(window: id, pane: paneID, tab: tab.id)
    }

    /// Sends `events` to `target`'s terminal by its id through the daemon that runs it (`DaemonService.type`): a
    /// local terminal's daemon, or for a remote-terminal tab its own session's daemon when that takes input by id.
    /// Only the keys the live view would send the same way go (``TypedTerminalInput/sendable(_:optionAsAlt:inputMethod:byName:)``);
    /// from the first that cannot, they stay for the view (``LaunchPictureKeys/SendOutcome/keptForView(taken:)``).
    /// Before the daemon's first connection they wait in its own queue (`onFirstConnection`), a measured stage; if
    /// startup gives up, the send fails and they are refused, their text kept.
    private static func sendKeys(_ events: [NSEvent], to target: Target, router: KeyRouter, answered: @escaping Answered) {
        guard let services = router.services, let first = destination(of: target, services: services) else {
            return answered(.keptForView(taken: 0))
        }
        let keys = router.launchPictureKeys
        let inputs = TypedTerminalInput.sendable(events, optionAsAlt: keys.optionAsAlt(), inputMethod: keys.selectsInputMethod(),
                                                 byName: first.surface != nil)
        guard !inputs.isEmpty else { return answered(.keptForView(taken: 0)) }
        let rest: SendOutcome = inputs.count < events.count ? .keptForView(taken: inputs.count) : .taken
        let waitsSince = first.daemon.awaitsFirstConnection ? keys.clock : nil
        first.daemon.onFirstConnection { [weak services, weak keys] in
            if let waitsSince { keys?.noteWait(.daemonNotConnected, keys: inputs.count, since: waitsSince) }
            // Read again: the first connection's tree may name the terminal's surface anew.
            guard let services, let now = destination(of: target, services: services) else { return answered(.keptForView(taken: 0)) }
            let wire = inputs.map { input -> TerminalTypedInput in
                switch input {
                case .text(let text): .text(text)
                case .key(let name): .key(name)
                }
            }
            now.daemon.type(wire, terminal: now.terminal, surface: now.surface) { taken, failure in
                switch failure {
                case nil: answered(rest)
                case .refused(let words)?: answered(.refused(taken: taken, reason: words))
                // Never sent again: it may have arrived. The person keeps its text and the rest's.
                case .mayNotHaveArrived(let words)?: answered(.mayNotHaveArrived(taken: taken, reason: words))
                }
            }
        }
    }

    /// The daemon that runs `target`'s terminal, its host id and its surface there (nil: a remote terminal, which has
    /// none on its own session). Nil while no daemon can take its input by id: the tab is not known yet, or a remote
    /// terminal's session is not connected or takes no input by id.
    private static func destination(of target: Target, services: AppServices) -> (daemon: DaemonService, terminal: TerminalID?, surface: SurfaceID?)? {
        guard let (tab, pane) = services.locateTab(target.tab) else { return nil }
        switch tab.kind {
        case .pty:
            return (services.daemon(for: pane), tab.terminalID, tab.surface)
        case .remoteTerminal:
            guard let ref = tab.remote, let daemon = services.machines.daemon(session: ref.sessionID), daemon.isLive,
                  daemon.supports(DaemonCapability.terminalInputWhileCreating.rawValue) else { return nil }
            return (daemon, ref.terminalID, nil)
        default:
            return nil
        }
    }

    /// Keys that reached nothing: a notice of its own says so, with the daemon's reason when it gave one, and keeps
    /// `text` (everything of `window` refused since the person was last done with it) on it until the person closes
    /// it; the refusal is logged on the refusal path (quiet: this notice is the one shown). Its Copy puts the text on
    /// the pasteboard only on a click, as a Cloud result's Copy does (`CloudPresenter`): the person's clipboard is
    /// never replaced unasked. Closing or copying ends the kept text. It shows in the window the keys were typed in.
    private static func refuseKeys(_ text: String, reason: String?, window: String, router: KeyRouter) {
        guard let services = router.services else { return }
        let notice = reason.map(RefusalStrings.launchTypingNotDeliveredBecause) ?? RefusalStrings.launchTypingNotDelivered
        services.registry.refuse(notice, quiet: true)
        guard let shell = services.windows.controller(for: window)?.window ?? NSApp.keyWindow ?? services.windows.active?.window else { return }
        let toast = CmuxToast(id: launchTypingToastID, message: notice, action: text.isEmpty ? nil : CmuxToast.Action(title: Strings.menuCopy),
                              duration: CmuxToast.untilClosed)
        let handle = CmuxToastCenter.shared.show(toast, in: shell), keys = router.launchPictureKeys
        handle.onAction = { [weak keys] in
            CloudPresenter.copy(text)
            keys?.forgetKept(window: window)
        }
        // A newer refusal replacing it carries the same text and more: the text stays kept for it.
        handle.onDismiss = { [weak keys] reason in if reason != .replaced { keys?.forgetKept(window: window) } }
    }

    /// The launch typing notice's toast id: a newer one replaces it, never the app's refusal toast.
    static let launchTypingToastID = "launch-typing-not-delivered"

    /// Sends `events`, typed in window `id` before it could decide them, through the router again, in order, as
    /// `CmuxApplication.sendEvent` would; false while the window still cannot decide them.
    private static func replayKeys(_ events: [NSEvent], window id: String, router: KeyRouter) -> Bool {
        guard let controller = router.services?.windows.controller(for: id), let shell = controller.window else { return false }
        if router.launchPictureKeys.showsPicture(window: id), !decidesKeys(controller.focus.state.resolved) { return false }
        for event in events {
            router.dispatchingSynthetic(event) {
                if !router.interceptKeyDown(event, in: shell) { shell.sendEvent(event) }
            }
        }
        return true
    }

    /// Gives `events` to `target`'s terminal view, in order, when the pane shows it; false when it does not. Each
    /// goes in the dispatch context `sendEvent` gives a key, so the terminal reports the key it took.
    private static func deliverKeys(_ events: [NSEvent], to target: Target, router: KeyRouter) -> Bool {
        guard let surface = liveSurface(of: target, router: router) else { return false }
        for event in events {
            router.dispatchingSynthetic(event) { surface.keyDown(with: event) }
        }
        return true
    }

    /// `target`'s terminal view, while its pane shows it in a window.
    private static func liveSurface(of target: Target, router: KeyRouter) -> TerminalSurfaceView? {
        guard let controller = router.services?.windows.controller(for: target.window),
              let pane = controller.content?.paneController(key: target.pane), pane.currentTabKey == target.tab,
              case .terminal(let entry)? = pane.currentContent else { return nil }
        let surface = entry.session.surfaceView
        return surface.window == nil ? nil : surface
    }
}
