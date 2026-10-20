import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextPages
import CmuxNextWakeups

/// A conversation tab's content (`conversation-tabs-v1`, home.md 7): the
/// native AppKit transcript (`HomeNativeTranscriptView`, MessagesLab's code,
/// home-mac.md) over the shared `HomeStore` of the local conversation owner,
/// or why it cannot show (the local daemon does not serve conversations).
@MainActor
final class HomeHostView: NSView {
    let transcript: HomeNativeTranscriptView
    private let message = ChromeLabel(labelWithString: "")
    private var availability: Task<Void, Never>?
    /// The Chief's settings, a popover under the header's name pill, which
    /// toggles it (Chief conversation only).
    private let settings: HomeChiefSettingsPopover
    private var settingsView: HomeChiefSettingsView { settings.content }
    private var isChief = false
    private var engineWatch: Task<Void, Never>?
    private var agentsWatch: Task<Void, Never>?
    private var shortcutsWatch: Task<Void, Never>?
    private var toggleObserver: (any NSObjectProtocol)?
    /// `home.toggleChiefSettings` (palette, `cmux action run`, preflight).
    static let toggleSettings = Notification.Name("HomeHostView.toggleChiefSettings")
    /// The Chief's tile avatar when its profile sets none: 🫡.
    static let defaultTileAvatar = HomeChiefAvatar.chiefDefault
    private var firstPage: Task<Void, Never>?
    /// Which brain answers this conversation (this Mac's or a paired server's).
    private var control: HomeChiefControl
    private var stopObserver: (any NSObjectProtocol)?
    /// The settings panel shows a paired server's brain (a cloud Chief).
    private var showsCloud = false
    private var isWorking = false
    /// Where this Chief runs and its other host, for the settings card (no floating switch over the chat).
    private var hostWatch: Task<Void, Never>?

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id,
                                              diagrams: service.diagrams)
        control = HomeChiefControl(services: services, conversation: id, muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        settings = HomeChiefSettingsPopover(content: HomeChiefSettingsView(muxHome: control.brainHome, source: control.engineSource()))
        super.init(frame: .zero)
        transcript.linkScheme = services.linkScheme  // "Copy Link" names messages in this build's scheme
        transcript.setNamePillHelp(HomeEngineStrings.pillHelp)
        // The header's name: the Chief's settings over a Chief; a DM's or group's info otherwise.
        transcript.onNamePill = { [weak self, weak services] in
            guard let self else { return }
            if isChief || settings.isShown { return toggleChiefSettings() }
            _ = services?.registry.perform("home.conversationInfo",
                                           invocation: ActionInvocation(arguments: ["conversation": .string(conversation)], origin: .user))
        }
        loadAvatar()
        settingsView.onAvatar = { [weak self, weak service] in
            self?.loadAvatar()
            // Each Chief's tile reads its own brain home: this re-reads them, so only the
            // Chief whose picture changed draws differently (cx-327wl).
            service?.refreshChiefAvatars()
        }
        // A new engine of this Chief: the Home list's badge follows it.
        settingsView.onEngineChanged = { [weak service] in service?.refreshChiefHarnesses() }
        // The card's "Switch to …": the same Chief on its other host takes the Chief tab.
        settingsView.onSwitchHost = { [weak service] in
            guard let service, let other = service.tabChiefs.otherHost(of: conversation) else { return }
            service.hostedChief.pick(other)
        }
        // task-owner: lives as long as this view; event-driven (Observation)
        hostWatch = Task { [weak self, weak service] in
            for await host in ObservationStream({ service?.chiefHost(of: conversation) ?? HomeChiefHostLine() }) {
                self?.settingsView.setHost(place: host.place, switchTo: host.switchTo)
            }
        }
        settingsView.onShowMemory = { [weak services] in
            _ = services?.registry.perform(ChiefInspectorHandlers.actionID, invocation: ActionInvocation(origin: .user))
        }
        settingsView.onRename = { [weak service] name in
            guard let connection = service?.connection else { return }
            // task-owner: one op; ends with its reply
            Task {
                let key = "home-chief-rename-\(UUID().uuidString.lowercased())"
                _ = try? await CmuxNextDaemon.ConversationClient(connection).op(
                    CmuxNextDaemon.ConversationOpRequest(conversation: conversation, idempotencyKey: key, transaction: nil, op: .setTitle(name)))
            }
        }
        toggleObserver = NotificationCenter.default.addObserver(forName: Self.toggleSettings, object: nil, queue: .main) { [weak self] note in
            // task-owner: one hop to the main actor for the toggle; only the front window's Home answers (the posted window)
            Task { @MainActor [target = (note.object as? NSWindow).map(ObjectIdentifier.init)] in if let self, HomeChiefSettingsPopover.answersToggle(for: target, in: self.window) { self.toggleChiefSettings() } }
        }
        // The shared stop action (palette, the stop button, Esc and Cmd-.): the key window's Home stops its Chief.
        let registry = services.registry
        transcript.onStop = { _ = registry.perform(HomeChiefControl.stopAction, invocation: ActionInvocation(origin: .user)) }
        // A cmux app link (a workspace, pane, tab, chat or Chief subagent): opened here, through link.open.
        transcript.onAppLink = { [weak services] url in if let services { CmuxAppLinks.open(url, services: services) } }
        // A link chip's hover card: the app's one coordinator, the target's live facts.
        transcript.enableLinkPreviews(coordinator: services.hoverCards, previewer: HomeLinkPreviewProvider(services: services))
        // Beside the pane showing this chat (the Home dock's: the first pane on its right), never the focused pane.
        transcript.onOpenLink = { [weak self] url, other in
            if let self { LinkRouter.shared.open(url, otherTarget: other, from: self) } else { LinkRouter.shared.open(url, otherTarget: other) }
        }
        // A link pressed and moved: dragged into the layout's drop zones, a split or a pane opens it (LinkDragSession).
        transcript.onDragLink = { [weak services] url, point in services?.linkDrags.begin(url, screenPoint: point) ?? false }
        stopObserver = NotificationCenter.default.addObserver(forName: HomeChiefControl.stopNotification, object: nil, queue: .main) { [weak self] _ in
            // task-owner: one hop to the main actor for the stop
            Task { @MainActor in self?.stopIfFront() }
        }
        let store = service.homeStore
        // task-owner: lives as long as this view; event-driven (Observation):
        // whether this is the Chief conversation, and a refresh of the
        // settings' last turn on each new message.
        engineWatch = Task { [weak self] in
            for await (isChief, _, title, cloud, typing, named) in ObservationStream({ () -> (Bool, Int, String, Bool, Bool, String?) in
                let row = store.rows.first { $0.summary.id == id }
                let chief = row?.summary.participants.contains { $0.agentClass == .chief } ?? false
                // A cloud Chief's brain runs on its paired server, never on
                // this Mac's mux home (2026-10-08: the sidebar wrote codex
                // here while cmux-lawrence ran claude-sr).
                return (chief, store.transcriptVersion[id] ?? 0, row?.summary.title ?? "", service.isCloudConversation(id),
                        row?.isTyping ?? false, row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) })
            }) {
                guard let self else { return }
                // A named Chief's conversation: its panel, Stop and avatar name it (cx-327wl).
                if named != control.chief {
                    control.chief = named
                    settingsView.use(control.engineSource())
                    loadAvatar()
                }
                self.isChief = isChief
                // The Chief types while its turn runs: the compose bar offers Stop.
                isWorking = isChief && typing
                transcript.isWorking = isWorking
                if cloud != showsCloud {
                    showsCloud = cloud
                    settingsView.use(control.engineSource())
                }
                settingsView.setName(title)
                if !isChief, settings.isShown { settings.close() }
                if settings.isShown { settingsView.refresh() }
            }
        }
        // Settings > Home: whether attached photos and videos keep their location.
        transcript.keepLocation = { [weak services] in services?.settings?.snapshot.homeKeepLocation ?? false }
        // The first-run rows run the same registry actions as the sidebar's
        // New Terminal Tab and New Agent Chat, and show their shortcuts.
        transcript.onFirstRunAction = { action in
            let id: ActionID = switch action {
            case .openTerminal: Self.openTerminalAction
            case .startAgent: Self.startAgentAction
            case .togglePet: "home.toggleChiefPet"
            }
            _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
        }
        // The first-run panel's agent rows open the agent's tab like a jump (Search Tabs).
        transcript.onFirstRunAgent = { [weak services] tab in _ = services?.revealTab(tab) }
        // task-owner: lives as long as this view; event-driven (Observation):
        // the user's agents for the first-run glance, only while it can show
        // (the Chief with no messages yet): otherwise no tab is read, so tab
        // changes never wake a Chief with history.
        agentsWatch = Task { [weak self] in
            var shown: [HomeAgentGlance] = []
            for await agents in ObservationStream({ () -> [HomeAgentGlance] in
                guard let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                      summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return [] }
                return HomeAgentGlances(services: services).current
            }) where agents != shown {
                shown = agents
                self?.transcript.setFirstRunAgents(agents)
            }
        }
        // The first-run rows' shortcuts and the Switching card follow rebinds
        // (Settings, cmux.json, keybindings.json) while the view lives.
        let switchKeys = services.homeSwitchKeys
        transcript.onHideSwitchKeys = { switchKeys.hide() }
        transcript.onOpenKeyboardShortcutSettings = {
            if let url = HomeSwitchKeysSource.keyboardShortcutsURL { NSWorkspace.shared.openInBackground(url) }
        }
        // task-owner: lives as long as this view; event-driven (Observation of the registry)
        shortcutsWatch = Task { [weak self] in
            for await keys in ObservationStream({
                HomeFirstRunKeys(terminal: registry.shortcutDisplay(for: Self.openTerminalAction),
                                 agent: registry.shortcutDisplay(for: Self.startAgentAction),
                                 switching: switchKeys.keys(registry: registry))
            }) {
                self?.transcript.setFirstRunShortcuts(terminal: keys.terminal, agent: keys.agent, switching: keys.switching)
            }
        }
        // The first-run panel waits for the first page, so a conversation
        // with history never flashes it (at once when the page is cached).
        transcript.holdsFirstRun = true
        let binding = transcript.binding
        // task-owner: lives as long as this view; ends when the first page is in
        firstPage = Task { [weak self] in
            await binding.opened()
            self?.transcript.holdsFirstRun = false
        }
        wantsLayer = true
        clipsToBounds = true
        message.alignment = .center
        // A long reason (a migration notice) wraps in a narrow pane instead of clipping.
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.wraps = true
        message.stringValue = HomeStrings.unavailable
        addSubview(transcript)
        addSubview(message)
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            // Usable when its own owner answers: a cloud conversation (a Chief
            // placed on a server) needs no local Chief owner.
            for await (available, online, why, notice) in ObservationStream({
                (service.isAvailable || service.isCloudConversation(id), service.homeStore.isOnline, service.unavailableMessage,
                 service.conversationNotice(for: id))
            }) {
                self?.transcript.isHidden = !available
                self?.message.isHidden = available
                self?.message.stringValue = why
                self?.transcript.showConversationNotice(notice)
                self?.needsLayout = true
                // H17: offline the user can type; tapbacks are off and a send waits as "sending".
                self?.transcript.isSendEnabled = online
            }
        }
    }

    static let openTerminalAction: ActionID = "newSurface"
    static let startAgentAction: ActionID = "palette.newAgentChat"

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            availability?.cancel()
            engineWatch?.cancel()
            hostWatch?.cancel()
            agentsWatch?.cancel()
            shortcutsWatch?.cancel()
            settings.close()
            if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            firstPage?.cancel()
            transcript.stop()
        }
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            // The pane paints under Home (`Palette.paneFill`).
            layer?.backgroundColor = nil
            message.textColor = Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        transcript.frame = bounds
        let inset: CGFloat = 24
        let width = max(0, bounds.width - 2 * inset)
        message.preferredMaxLayoutWidth = width
        let height = ceil(message.size(forWidth: width).height)
        message.frame = NSRect(x: inset, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// The name pill's click (or `home.toggleChiefSettings`): the Chief's
    /// settings open under the pill, or close again. Only over the Chief.
    func toggleChiefSettings() {
        if settings.isShown { return settings.close() }
        guard isChief, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        settingsView.refresh()
        settings.show(relativeTo: transcript.namePill, toggles: transcript.namePillToggles)
    }

    /// The popover is a child panel of the window, not a subview: Home leaving
    /// its window (a tab or workspace switch, Cmd-W) or hiding closes it, so it
    /// never stays over the next pane.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { settings.close() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        settings.close()
    }

    /// The shared stop action reached this view: only the Home in the key
    /// window stops its Chief, and only while it works.
    private func stopIfFront() {
        guard isChief, isWorking, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        let control = control
        // task-owner: one chief.stop; ends with its answer
        Task {
            if await control.stop() != nil { NSSound.beep() }
        }
    }

    /// Where this Chief's picture is kept: the daemon's Chief registry for a Chief of this Mac
    /// (the store the profile and chiefs tools write); nil for a cloud Chief (its files).
    private func pictureStore() -> (avatars: HomeChiefAvatars, chief: String)? {
        guard !control.isCloud else { return nil }
        let avatars = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: control.services.environment.tag),
                                       registry: DaemonChiefAvatarRegistry(connection: control.connection))
        return (avatars, HomeChiefAvatars.chiefID(named: control.named))
    }

    /// The header avatar of the Chief shown here: its registry picture, else its profile's text.
    private func loadAvatar() {
        let home = control.brainHome
        let files = HomeChiefFiles(muxHome: home)
        let store = pictureStore()
        settingsView.pictureStore = store
        // task-owner: one avatar read (registry, else files off the main actor); ends when it is shown
        Task { [weak self] in
            let avatar: (text: String?, picture: Data?)
            if let store {
                switch await store.avatars.read(chief: store.chief) {
                case .picture(let url)?: avatar = (nil, await Task.detached { try? Data(contentsOf: url) }.value)
                case .text(let text)?: avatar = (text, nil)
                case nil: avatar = (nil, nil)
                }
            } else {
                avatar = await Task.detached { files.headerAvatar() }.value
            }
            // A read for the Chief shown before (the conversation's Chief came in since) is dropped.
            guard let self, control.brainHome == home else { return }
            let picture = avatar.picture.flatMap(NSImage.init(data:))
            let text = HomeChiefAvatar.headerText(avatar.text, hasPicture: picture != nil)
            transcript.setChiefAvatar(picture: picture, text: text)  // the header and the first-run hero
            settingsView.setAvatar(picture: picture, text: text)
        }
    }

    #if DEBUG
    /// `debug.home.drive` engine_set: one pick in this view's Chief settings panel, as its popup does.
    func debugPickEngine(_ key: String, _ value: String?) { settingsView.pick(key, value) }
    /// `debug.home.drive` chief_control: the named Chief this view's controls name (nil: the default).
    var debugNamedChief: String? { control.named }
    #endif

    /// The transcript header's height (New Message's To: field covers it).
    var headerHeight: CGFloat { transcript.headerHeight }

    /// The view that takes the keyboard when the tab's pane is focused.
    /// Home's primary input: the message box itself. Focusing the transcript
    /// view would leave it the responder after it forwards to the box.
    var focusTarget: NSView { transcript.primaryInput }

    /// The person opened this conversation from Home (a click, Return, a switch key): the message
    /// box takes the keyboard, at once or once its first page installs it.
    func takeKeyboardOnOpen() { transcript.takeKeyboardOnOpen() }

    /// Whether the pane getting focus moves the keyboard to `focusTarget`
    /// from `responder`: always when it is outside this view; inside, unless
    /// a visible, editable text input has it or the transcript holds a text
    /// selection (the pane, a header button or the bare transcript gave the
    /// person a Home with nowhere to type, Lawrence 2026-10-18). A hidden or
    /// read-only text view is no place to type (the Chief settings' name
    /// field after the panel closed kept the keyboard, Lawrence 2026-10-19).
    func focusTargetShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, view === self || view.isDescendant(of: self) else { return true }
        if view === focusTarget || view.ownsTypedText { return false }
        if view is NSText || view is NSTextField { return true }
        return transcript.primaryInputShouldTakeKeyboard(from: responder)
    }
}

extension HomeHostView: NSMenuItemValidation {
    /// Cmd+V that no text view in Home took: the message box takes the
    /// keyboard and the paste (the transcript's pane routes its own first).
    @objc func paste(_ sender: Any?) { transcript.paste(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(paste(_:)) else { return true }
        return transcript.canPasteIntoPrimaryInput
    }
}

/// Home's primary input is its message box (R65, spec app-screens.md 3):
/// the pane getting focus by any path lands the keyboard there, and a
/// printable key typed while Home has the keyboard but no text input of it
/// does (a click on a bubble left the transcript focused, a hidden field kept
/// it) moves the keyboard to the box and types the key there (the protocol's
/// default `acceptsRedirectedTyping` and `beginTyping`).
extension HomeHostView: PrimaryInputTarget {
    var primaryInputView: NSView? { focusTarget }

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        focusTargetShouldTakeKeyboard(from: responder)
    }
}
