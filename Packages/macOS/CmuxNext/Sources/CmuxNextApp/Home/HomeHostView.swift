import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextChiefMemory
import CmuxNextChiefPetWiring
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextLayout
import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextWakeups
import ImageIO

/// A conversation tab's content (`conversation-tabs-v1`, home.md 7): the
/// native AppKit transcript (`HomeNativeTranscriptView`, MessagesLab's code,
/// home-mac.md) over the shared `HomeStore` of the local conversation owner,
/// or why it cannot show (the local daemon does not serve conversations).
@MainActor
final class HomeHostView: NSView, PaneCommitMotionPicture {
    let transcript: HomeNativeTranscriptView
    private let message = HomeUnavailableLabel.make(HomeStrings.unavailable)
    private var availability: Task<Void, Never>?
    /// The Chief's settings, a popover under the header's name pill, which toggles it (Chief
    /// conversation only), made on its first open (``HomeChiefSettingsCard``), never by a switch.
    private let card = HomeChiefSettingsCard()
    private var petRows: ChiefPetSettingsRows?  // the pet's rows in the popover's Appearance section, made with it
    /// The Chief whose character the popover offers and the header wears (nil: the default Chief).
    private var petChief: String? { didSet { if petChief != oldValue { petRows?.chief = petChief; followChosenPicture() } } }
    private(set) var isChief = false { didSet { if isChief != oldValue { watchHeaderPanels(); watchNeedsYou(); watchSetupCard() } } }
    /// The header's top-right panel toggles follow their panels (HomeHostView+HeaderPanels.swift).
    var headerPanelsWatch: Task<Void, Never>?
    /// A Chief's pinned Needs you section follows the Feed's open requests (HomeHostView+NeedsYou.swift).
    var needsYouWatch: Task<Void, Never>?
    /// A Chief's Set Up cmux card at first run follows ``FirstRunSetup`` (HomeHostView+SetupCard.swift).
    var setupCardWatch: Task<Void, Never>?
    var setupCard: SetupCardHost?
    private var engineWatch: Task<Void, Never>?
    /// Each Chief's avatar beside this conversation's group bubbles, as its Home row draws it.
    private var avatarsWatch: Task<Void, Never>?
    private var agentsWatch: Task<Void, Never>?
    private var chiefIntroWatch: Task<Void, Never>?
    private var chiefOnboardingWatch: Task<Void, Never>?
    private var shortcutsWatch: Task<Void, Never>?
    private var spellCheckingWatch: Task<Void, Never>?
    /// The Chief's avatar when its profile sets none: `picture` (`AppServices.chosenPicture(of:)`, its
    /// upload or picked character), else its monogram (``HomeChiefAvatar/chiefDefault``, CH; Lawrence 2026-10-30).
    static func defaultTileAvatar(picture: URL?) -> HomeChiefAvatar { picture.map(HomeChiefAvatar.picture) ?? .chiefDefault }
    private var firstPage: Task<Void, Never>?
    /// Which brain answers this conversation (this Mac's or a paired server's).
    private(set) var control: HomeChiefControl
    /// The settings panel shows a cloud Chief's brain, and whether the Cloud service hosts it
    /// (else a paired server runs it).
    private var showsCloud = false
    private var showsHosted = false
    private var isWorking = false
    /// The Chief is answering (Esc stops it; the floating Chief panel hides on Esc only when it is not).
    lazy var turnActions = control.services.home.chiefHomes.turnActions(for: transcript)
    /// What this Home's stop button runs on it; tests watch it.
    var stopChief: @MainActor (HomeHostView) -> Void = { HomeChiefActions.stop(shown: $0) }
    /// Where this Chief runs and its other host, for the settings card (no floating switch over the chat).
    private var hostWatch: Task<Void, Never>?
    /// The card's Runs On chip, on the Chief that `cmux chief move` moves (the header has none).
    private var runsOn: ChiefRunsOnChip?
    /// Where attachments open and their right-click menu (the transcript holds it weakly).
    private var fileActions: HomeFileActions?

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The conversation this view shows (`HomeService.debugHostViews`).
    var debugConversation: String { control.conversation.rawValue }
    #endif

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id, diagrams: service.diagrams,
                                              openPanel: services.openPanel, composerFocused: { DebugTimings.markLaunch($0.window?.isKeyWindow == true ? "window_usable" : "home.composer_focused_not_key") }) // window_usable: the next key goes in (piece 8)
        let approvals = ChiefApprovalDecider(home: service.chief.home, app: QuitAgents.environment(services),
                                             work: services.work, environment: ChiefHomeAcpmux.environment)
        transcript.approvals = approvals
        let person = PersonInputCheck(sources: services.personInput.sources)
        transcript.isPersonApprovalEvent = { person.isPerson($0) }
        transcript.composerSpellCheckingEnabled = services.settings?.snapshot.agentPaneComposer.spellChecking ?? false
        control = HomeChiefControl(services: services, conversation: id, muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        super.init(frame: .zero)
        #if DEBUG || CMUX_BENCH_HOOKS
        service.debugHostViews.add(self)
        #endif
        transcript.linkScheme = services.linkScheme  // "Copy Link" names messages in this build's scheme
        transcript.setNamePillHelp(HomeEngineStrings.pillHelp)
        // The header's name: the Chief's settings over a Chief; a DM's or group's info otherwise.
        transcript.onNamePill = { [weak self, weak services] in
            guard let self else { return }
            if isChief || card.isShown { toggleChiefSettings(); return }
            _ = services?.registry.perform("home.conversationInfo",
                                           invocation: ActionInvocation(arguments: ["conversation": .string(conversation)], origin: .user))
        }
        loadAvatar()
        // The header's top-right toggles (Share Screen, Memory): each runs its panel's action.
        transcript.onHeaderPanel = { [weak self] id in
            if let self { HomeHeaderPanels.toggle(id, headerPanelContext) }
        }
        followChosenPicture()
        transcript.chatColors = service.chatColors  // Chat Colors…: this chat's own colours, live
        // task-owner: lives as long as this view; event-driven (Observation)
        hostWatch = Task { [weak self, weak service] in
            for await host in ObservationStream({ service?.chiefHost(of: conversation) ?? HomeChiefHostLine() }) {
                self?.card.setHost(host)
            }
        }
        runsOn = ChiefRunsOnChip(model: services.chiefTeleport)
        runsOn?.follow(for: self, { [weak service] in service?.showsTeleport(conversation: conversation) ?? false }) { [weak self] in
            self?.card.showTeleport($0)
        }
        // The stop button (HomeHostView+StopAll): a click, Esc and Cmd-. stop the Chief; Option-click stops all agents.
        let registry = services.registry
        wireStopButton()
        // A cmux app link (a workspace, pane, tab, chat or Chief subagent): opened here, through link.open.
        // An attachment or a path link opens in cmux on the right of Home, never in Finder (a
        // folder in a Files tab); right-click has Open With (HomeFileActions).
        let fileActions = HomeFileActions(services: services)
        self.fileActions = fileActions
        transcript.fileHost = fileActions
        transcript.onAppLink = { [weak self, weak services, weak fileActions] url in
            if url.isFileURL, url.path.hasPrefix("/") { fileActions?.open(URL(fileURLWithPath: url.path)); return }
            guard let services else { return }
            // A link to elsewhere opens only its target; the floating Chief comes with it only when the person
            // turned on `home.chiefDock.openBeside` (off by default, cmux#45889).
            WindowDockActions(host: services).chiefLinkWillOpen(in: self?.window.flatMap(services.windows.owner(of:)))
            CmuxAppLinks.open(url, services: services, click: .init(source: self.flatMap(LinkRouter.shared.sourceTab)))
        }
        // A link chip's hover card: the app's one coordinator, the target's live facts.
        transcript.enableLinkPreviews(coordinator: services.hoverCards, previewer: HomeLinkPreviewProvider(services: services))
        // Beside the pane showing this chat (the Home dock's: the first pane on its right), never the focused pane.
        transcript.onOpenLink = { [weak self] url, other in
            if let self { LinkRouter.shared.open(url, otherTarget: other, from: self) } else { LinkRouter.shared.open(url, otherTarget: other) }
        }
        // A link pressed and moved: dragged into the layout's drop zones, a split or a pane opens it (LinkDragSession).
        transcript.onDragLink = { [weak services] url, point in services?.linkDrags.begin(url, screenPoint: point) ?? false }
        // Forward… on a bubble: Send To… with its text (the palette asks where).
        transcript.onForward = { text in
            _ = registry.perform("home.sendSelectionTo", invocation: ActionInvocation(arguments: ["text": .string(text)], origin: .user))
        }
        let store = service.homeStore
        // task-owner: lives as long as this view; event-driven (Observation):
        // whether this is the Chief conversation, and a refresh of the
        // settings' last turn on each new message.
        engineWatch = Task { [weak self] in
            for await (isChief, _, title, cloud, typing, named, hosted, participant, lastSeq) in ObservationStream({
                () -> (Bool, Int, String, Bool, Bool, String?, Bool, String?, Seq) in
                let row = store.rows.first { $0.summary.id == id }
                let chief = row?.summary.participants.contains { $0.agentClass == .chief } ?? false
                // A cloud Chief's brain runs on its paired server, never on
                // this Mac's mux home (2026-10-08: the sidebar wrote codex
                // here while cmux-lawrence ran claude-sr).
                // The Chief's own name (HomeService.chiefName(of:)), the one its tile and tab show.
                let name = service.chiefName(of: id)
                return (chief, store.transcriptVersion[id] ?? 0, name ?? row?.summary.title ?? "", service.isCloudConversation(id),
                        row?.isTyping ?? false, row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) },
                        service.cloudChiefPlacement(of: conversation)?.placed != true,
                        row.flatMap { HomeService.soleChief(of: $0.summary.participants) }, row?.summary.lastSeq ?? 0)
            }) {
                guard let self else { return }
                // A named Chief's conversation: its panel, Stop and avatar name it (cx-327wl).
                if named != control.chief {
                    control.chief = named
                    card.view?.use(control.engineSource())
                    loadAvatar()
                }
                // The popover's characters are this Chief's own (a new one redraws the header).
                petChief = participant
                self.isChief = isChief
                openPendingSettings()
                isWorking = isChief && typing
                transcript.isWorking = isWorking
                turnActions.update(control: control.turnControl, isChief: isChief, working: isWorking, sequence: lastSeq)
                if cloud != showsCloud || (cloud && hosted != showsHosted) {
                    showsCloud = cloud
                    showsHosted = hosted
                    card.view?.use(control.engineSource())
                }
                card.setName(title)
                transcript.headerTitle = isChief ? service.chiefName(of: id) : nil
                if card.isShown { if isChief { card.view?.refresh() } else { card.close() } }
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation): each Chief of
        // this conversation wears its Home row's avatar beside a group's bubbles, again after a
        // swap (a Chief's picture or text, the pet character a Chief with none wears).
        avatarsWatch = Task { [weak self, weak service] in
            for await avatars in ObservationStream({ () -> [String: HomeChiefAvatar] in
                guard let service else { return [:] }
                let participants = store.rows.first { $0.summary.id == id }?.summary.participants ?? []
                return HomeChiefAvatar.bubbleAvatars(for: participants, own: service.chiefFaces, fallback: .chiefDefault)  // own picks: chiefFaces
            }) {
                self?.transcript.setChiefBubbleAvatars(avatars)
            }
        }
        // Settings > Home: whether attached photos and videos keep their location.
        transcript.keepLocation = { [weak services] in services?.settings?.snapshot.homeKeepLocation ?? false }

        spellCheckingWatch = Task { [weak self, weak services] in
            for await enabled in ObservationStream({ services?.settings?.snapshot.agentPaneComposer.spellChecking ?? false }) {
                self?.transcript.composerSpellCheckingEnabled = enabled
            }
        }
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
        // task-owner: lives as long as this view; event-driven (Observation): the user's agents for the first-run
        // glance, only while it can show (the Chief with no messages yet): otherwise no tab is read, so tab changes
        // never wake a Chief with history. The feed reads one workspace in each observation: a new tab wakes no stream here.
        let agentsFeed = HomeAgentGlances(services: services).feed {
            store.rows.first { $0.summary.id == id }.map { $0.summary.lastSeq == 0 && $0.summary.participants.contains { $0.agentClass == .chief } } ?? false
        }
        agentsWatch = Task { [weak self] in
            agentsFeed.start()
            for await case let (agents, starters)? in ObservationStream({ () -> ([HomeAgentGlance], HomeStarterContext)? in
                guard let agents = agentsFeed.observedItems?.flatMap({ $0 }) else { return nil }
                return (agents, HomeAgentGlances(services: services).starters(agents: agents, badges: SidebarSessionTree.shared.pullRequests))
            }) {
                self?.transcript.setFirstRunAgents(agents)
                self?.transcript.setFirstRunStarters(starters)
            }
            agentsFeed.stop() // the view's release cancelled this task: the feed's observations end with it
        }
        // Onboarding: the Chief's first-open message, contextual (ChiefIntroStore). The only Chief welcomes once per
        // install in the chat itself (ChiefWelcome: its typing dots, then its messages, drawn by the iMessage
        // transcript); a Chief made beside others asks what to focus on, once per Chief. It shows on the Chief's
        // front page (no messages yet). A fresh install hides the first-run panel from the start, so it never
        // flashes before the welcome.
        let intro = ChiefIntroStore(defaults: .standard)
        transcript.welcomesInChat = intro.welcomePending && !service.isCloudConversation(id)
        // Meet Chief (ChiefOnboarding) comes first on a fresh install: the welcome waits until it ends.
        let onboarding = services.onboarding.chief
        let archived: @MainActor @Sendable () -> Set<String> = { service.directory.archivedChiefs }
        chiefIntroWatch = intro.follow(in: transcript, conversation: id, store: store, archivedChiefs: archived, holds: { onboarding.holdsWelcome }) {
            service.chiefWelcome.play(in: id, source: service.homeSource, connection: service.isCloudConversation(id) ? nil : service.chief.connection,
                                      intro: intro, text: ChiefWelcome.text(services.registry, anyAppOn: services.settings?.snapshot.startAgentGlobalHotKey ?? false))
        }
        chiefOnboardingWatch = onboarding.follow(in: transcript, conversation: id, store: store, archivedChiefs: archived, registry: services.registry)
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
        let reveal = services.launchReveal, spareWait = services.newTabSpares.shownChats // the launch's New Tab spare waits for this page
        // task-owner: lives as long as this view; ends when the first page is in
        firstPage = Task { [weak self] in
            await binding.firstDrawable() // the first page, or an owner-named empty conversation: nothing to read for
            // A Home released before its page came (deinit cancels this) must not
            // reveal the Home that replaced it, which waits for its own page.
            guard let self, !Task.isCancelled else { return }
            transcript.holdsFirstRun = false
            // A launch holds a Home still being made until here (WorkspaceContentController).
            reveal.markReady(.home); DebugTimings.markLaunch("home.first_page"); spareWait.homePageDrew()
        }
        wantsLayer = true
        clipsToBounds = true
        addSubview(transcript)
        addSubview(message)
        // task-owner: lives as long as this view; event-driven (Observation)
        availability = Task { [weak self] in
            // Usable when its own owner answers: a cloud conversation (a Chief
            // placed on a server) needs no local Chief owner.
            for await (available, explained, online, why, notice) in ObservationStream({
                (service.isAvailable || service.isCloudConversation(id), service.isRefused || service.migrationNotice != nil,
                 service.homeStore.isOnline, service.unavailableMessage, service.conversationNotice(for: id))
            }) {
                // An unanswered availability check is still loading: keep Home's existing
                // transcript loading/connecting treatment visible instead of leaving a blank pane.
                self?.transcript.isHidden = !available && explained
                self?.message.isHidden = available || !explained
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
    // The last reference can go on any thread (OffMainReleaseCleanupTests' shape, 39256ad7181): the observation
    // Tasks are Sendable and end here. Two stops are main-actor work with no Sendable handle, so they run on the
    // main actor: the settings popover's window, and the transcript's stop, which releases its dictation claim in
    // the app's claim registry and cancels its wake on the app's timer (both outlive this view). A guard that
    // returned off main skipped all of it.
    nonisolated deinit {
        for task in [availability, engineWatch, avatarsWatch, hostWatch, agentsWatch, shortcutsWatch, spellCheckingWatch, headerPanelsWatch, needsYouWatch, setupCardWatch, firstPage, chiefIntroWatch, chiefOnboardingWatch] {
            task?.cancel()
        }
        let card = card, transcript = transcript, setupCard = setupCard
        // task-owner: the main-actor half of this view's release; one call each, then it ends
        Task { @MainActor in
            card.close()
            setupCard?.close()
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
        message.place(in: bounds)
    }

    /// The name pill's click (or `home.toggleChiefSettings`): the Chief's settings open under the pill, or
    /// close again (never with `openOnly`, the pet's Chief Pet Settings…). Only over the Chief. True if shown.
    @discardableResult func toggleChiefSettings(openOnly: Bool = false) -> Bool {
        if card.isShown { if !openOnly { card.close() }; return openOnly }
        guard isChief, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        card.view?.refresh()  // a card made now reads its engine as it is made
        return chiefSettings().show(relativeTo: transcript.namePill, toggles: transcript.namePillToggles)
    }

    /// The Chief's settings popover, made and wired on its first open.
    private func chiefSettings() -> HomeChiefSettingsPopover { card.made({ HomeChiefSettingsView(muxHome: control.brainHome, source: control.engineSource()) }, configure: wire) }

    private func wire(_ settingsView: HomeChiefSettingsView) {
        let services = control.services, service = services.home, conversation = control.conversation.rawValue
        let petRows = ChiefPetSettingsRows(settings: { [weak services] in services?.settings }, homes: services.chiefPetHomes, picks: services.chiefMascotPicks, uploads: services.chiefAvatarUploads)
        (petRows.chief, self.petRows) = (petChief, petRows)
        petRows.onRefusal = { [settingsView] in settingsView.showNote($0) }  // why an upload was refused
        petRows.install(in: self, addRow: { [settingsView] in settingsView.addAppearanceRow($0, control: $1) },
                        open: { [weak self] in self?.toggleChiefSettings(openOnly: true) ?? false })
        // Each Chief's tile reads its own brain home: this re-reads them, so only the
        // Chief whose picture changed draws differently (cx-327wl).
        settingsView.onAvatar = { [weak self, weak service] in self?.loadAvatar(); service?.refreshChiefAvatars() }
        // A new engine of this Chief: the Home list's badge follows it.
        settingsView.onEngineChanged = { [weak service] in service?.refreshChiefHarnesses() }
        // The card's "Switch to …": the same Chief on its other host takes the Chief tab.
        settingsView.onSwitchHost = { [weak service] in
            guard let service, let other = service.tabChiefs.otherHost(of: conversation) else { return }
            service.hostedChief.pick(other)
        }
        // Show Memory: this conversation's Chief (a named local Chief, or a
        // cloud Chief's paired server), not only the default one.
        settingsView.onShowMemory = { [weak self, weak services] in
            let control = self?.control, server = control?.server?.machineID, chief = control?.named
            let arguments: [String: ActionValue] = server.map { ["server": .string($0)] } ?? chief.map { ["chief": .string($0)] } ?? [:]
            _ = services?.registry.perform(ChiefInspectorHandlers.actionID, invocation: ActionInvocation(arguments: arguments, origin: .user))
        }
        settingsView.recents = services.chiefModelRecents
        // All Chief Settings…: Settings > Chief, the page with every Chief setting.
        settingsView.onAllSettings = { [weak self, weak services] in
            self?.card.close()
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
        }
        settingsView.checkHarness = { [weak services] id in (try? await services?.agentHarnesses.doctor(id: id))?["ok"]?.boolValue == true }
        // Every harness this Mac's acpmux has (Settings > Agents' list), after the official engines.
        settingsView.listHarnesses = { [weak services] in (try? await services?.agentHarnesses.listed())?.sorted() ?? [] }
        // One rename path for every Chief (HomeService.renameChief): every surface shows the new name at once.
        settingsView.onRename = { [weak service] name in
            await service?.renameChief(conversation: conversation, to: name) ?? .noConnection
        }
        settingsView.bindPrimary(directory: service.directory, conversation: conversation)  // the Primary Chief row
    }

    /// The header redraws its avatar when the Chief's picked character or upload changes.
    private func followChosenPicture() { let (services, chief) = (control.services, petChief); card.followPicture({ [weak services] in services?.chosenPicture(of: chief) }) { [weak self] in self?.loadAvatar() } }

    /// The popover is a child panel of the window, not a subview: Home leaving
    /// its window (a tab or workspace switch, Cmd-W) or hiding closes it, so it
    /// never stays over the next pane.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { card.close() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        openPendingSettings()
        watchHeaderPanels()
    }

    override func viewDidHide() {
        super.viewDidHide()
        card.close()
    }

    /// This view shows a Chief conversation on screen: the front window's Home that
    /// `home.stopChief` and `home.toggleChiefSettings` act on (`HomeChiefActions`).
    var showsChiefOnScreen: Bool { isChief && window != nil && !isHiddenOrHasHiddenAncestor }
    /// The shown Chief's turn runs.
    var chiefIsWorking: Bool { isWorking }
    /// The shown Chief's control (`chief.stop`).
    var chiefControl: HomeChiefControl { control }

    /// Opens the settings `HomeChiefActions` asked for once this view shows its Chief (Toggle Chief
    /// Settings with no Home in front brought Home forward at this conversation).
    private func openPendingSettings() {
        let home = control.services.home
        guard showsChiefOnScreen, home.pendingChiefSettings == control.conversation else { return }
        home.pendingChiefSettings = nil
        toggleChiefSettings(openOnly: true)
    }

    /// Where this Chief's picture is kept: the daemon's Chief registry for a Chief of this Mac
    /// (the store the profile and chiefs tools write); nil for a cloud Chief (its files).
    private func pictureStore() -> (avatars: HomeChiefAvatars, chief: String)? {
        guard !control.isCloud else { return nil }
        let avatars = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: control.services.environment.tag),
                                       registry: DaemonChiefAvatarRegistry(connection: control.connection))
        return (avatars, HomeChiefAvatars.chiefID(named: control.named))
    }

    /// The picture the Chief shown here wears where its profile sets none: its upload, else its pick, else nil.
    private var fallbackPicture: URL? {
        control.services.chosenPicture(of: petChief)
    }

    /// The header avatar of the Chief shown here: its registry picture, else its profile's text,
    /// else its worn upload, else nil and the header draws its name's monogram.
    private func loadAvatar() {
        let home = control.brainHome
        let files = HomeChiefFiles(muxHome: home)
        let store = pictureStore()
        card.setPictureStore(store)
        let fallback = fallbackPicture
        // task-owner: one avatar read (registry, else files off the main actor); ends when it is shown
        Task { [weak self] in
            let avatar = if let store {
                await store.avatars.headerAvatar(chief: store.chief, fallback: fallback)
            } else {
                await HomeChiefAvatars.headerAvatar(files: files, fallback: fallback)
            }
            // Decoded off the main actor: an upload's still or the registry picture.
            let data = avatar.picture
            // task-owner: one decode of the avatar picture; ends when it is shown
            let decoded = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { data.flatMap(Self.decode) }.value
            // A read for the Chief or the character shown before (another came in since) is dropped.
            guard let self, control.brainHome == home,
                  fallback == fallbackPicture else { return }
            let picture = decoded.map { NSImage(cgImage: $0, size: .zero) }
            let text = avatar.text  // nil: the header and the hero draw the name's monogram (CH)
            transcript.setChiefAvatar(picture: picture, text: text)  // the header and the first-run hero
            card.setAvatar(picture: picture, text: text ?? transcript.shownMonogram)
        }
    }

    /// The first frame of the picture `data` holds, decoded now.
    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.home.drive` engine_set: one pick in this view's Chief settings panel, as its popup does.
    func debugPickEngine(_ key: String, _ value: String?) { chiefSettings().content.pick(key, value) }
    /// `debug.home.api` edit_picture: a picture picked or dropped on this view's Chief card (Move and Scale).
    func debugEditPicture(_ source: URL, zoom: CGFloat?, save: Bool) async -> Bool? {
        loadAvatar()
        return await chiefSettings().content.debugEditPicture(source, zoom: zoom, save: save)
    }
    /// `debug.home.drive` chief_name: the settings open with the keyboard in the name field (`close`: they close, as a click outside).
    func debugEditChiefName(close: Bool) -> Bool { if close { card.close(); return true }; return toggleChiefSettings(openOnly: true) && card.view?.beginEditingName() == true }
    /// `debug.home.drive` chief_control: the named Chief this view's controls name (nil: the default).
    var debugNamedChief: String? { control.named }
    #endif

    /// The transcript header's height (New Message's To: field covers it).
    var headerHeight: CGFloat { transcript.headerHeight }

    /// The view that takes the keyboard when the tab's pane is focused.
    /// Home's message box (focusing the transcript would leave it the responder
    /// after it forwards), or the picture viewer while it is open over the chat.
    var focusTarget: NSView { transcript.keyboardTarget }

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
extension HomeHostView: ChiefPanelContent { var chiefIsAnswering: Bool { isWorking }; var chiefShowsThrough: Bool { get { transcript.clearsBackground } set { transcript.clearsBackground = newValue } }; var chiefHeaderHeight: CGFloat { headerHeight } }
