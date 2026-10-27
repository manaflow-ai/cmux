import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextChiefPetWiring
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextPages
import CmuxNextSidebar
import CmuxNextWakeups
import ImageIO

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
    /// The Chief pet's rows in the popover's Appearance section.
    private let petRows: ChiefPetSettingsRows
    private(set) var isChief = false { didSet { if isChief != oldValue { watchHeaderPanels() } } }
    /// The header's top-right panel toggles follow their panels (HomeHostView+HeaderPanels.swift).
    var headerPanelsWatch: Task<Void, Never>?
    private var engineWatch: Task<Void, Never>?
    /// Each Chief's avatar beside this conversation's group bubbles, as its Home row draws it.
    private var avatarsWatch: Task<Void, Never>?
    private var agentsWatch: Task<Void, Never>?
    private var memoryOfferWatch: Task<Void, Never>?
    /// UserDefaults: the first-run memory offer was clicked (it shows once).
    static let memoryOfferUsedKey = "home.firstRun.memoryOfferUsed"
    private var shortcutsWatch: Task<Void, Never>?
    private var spellCheckingWatch: Task<Void, Never>?
    /// The Chief's avatar when its profile sets none: the pet character `mascot` picks
    /// (`home.chiefPetMascot`; Leo 2026-10-20: one of the nine characters, never a plain circle),
    /// else 🫡 if its picture is missing from the bundle.
    static func defaultTileAvatar(mascot: String?) -> HomeChiefAvatar { defaultTileAvatar(picture: ChiefPetSettingsRows.avatarURL(of: mascot)) }
    /// The same from the picture the default Chief wears (`AppServices.characterPicture(of:)`: its upload, else its character).
    static func defaultTileAvatar(picture: URL?) -> HomeChiefAvatar { picture.map(HomeChiefAvatar.picture) ?? .chiefDefault }
    private var firstPage: Task<Void, Never>?
    /// Which brain answers this conversation (this Mac's or a paired server's).
    private(set) var control: HomeChiefControl
    /// The settings panel shows a cloud Chief's brain, and whether the Cloud service hosts it
    /// (else a paired server runs it).
    private var showsCloud = false
    private var showsHosted = false
    private var isWorking = false
    /// Where this Chief runs and its other host, for the settings card (no floating switch over the chat).
    private var hostWatch: Task<Void, Never>?
    /// Where attachments open and their right-click menu (the transcript holds it weakly).
    private var fileActions: HomeFileActions?

    init(services: AppServices, conversation: String) {
        let service = services.home
        let id = ConversationID(conversation)
        transcript = HomeNativeTranscriptView(store: service.homeStore, conversation: id, me: service.homeSource.me.id,
                                              diagrams: service.diagrams, openPanel: services.openPanel)
        transcript.composerSpellCheckingEnabled = services.settings?.snapshot.agentPaneComposer.spellChecking ?? false
        control = HomeChiefControl(services: services, conversation: id, muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        settings = HomeChiefSettingsPopover(content: HomeChiefSettingsView(muxHome: control.brainHome, source: control.engineSource()))
        petRows = ChiefPetSettingsRows(settings: { [weak services] in services?.settings }, homes: services.chiefPetHomes,
                                       picks: services.chiefMascotPicks, uploads: services.chiefAvatarUploads)
        super.init(frame: .zero)
        transcript.linkScheme = services.linkScheme  // "Copy Link" names messages in this build's scheme
        transcript.setNamePillHelp(HomeEngineStrings.pillHelp)
        // The header's name: the Chief's settings over a Chief; a DM's or group's info otherwise.
        transcript.onNamePill = { [weak self, weak services] in
            guard let self else { return }
            if isChief || settings.isShown { toggleChiefSettings(); return }
            _ = services?.registry.perform("home.conversationInfo",
                                           invocation: ActionInvocation(arguments: ["conversation": .string(conversation)], origin: .user))
        }
        loadAvatar()
        // The header's top-right toggles (Memory, Right Sidebar): each runs its panel's action.
        transcript.onHeaderPanel = { [weak self] id in
            if let self { HomeHeaderPanels.toggle(id, headerPanelContext) }
        }
        petRows.onMascot = { [weak self] in self?.loadAvatar() }  // a new character redraws the header at once
        petRows.onRefusal = { [settingsView] in settingsView.showNote($0) }  // why an upload was refused
        petRows.install(in: self, addRow: { [settingsView] in settingsView.addAppearanceRow($0, control: $1) },
                        open: { [weak self] in self?.toggleChiefSettings(openOnly: true) ?? false })
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
        // Show Memory: this conversation's Chief (a named local Chief, or a
        // cloud Chief's paired server), not only the default one.
        settingsView.onShowMemory = { [weak self, weak services] in
            var invocation = ActionInvocation(origin: .user)
            if let control = self?.control {
                if let machine = control.server?.machineID {
                    invocation.arguments["server"] = .string(machine)
                } else if let chief = control.named {
                    invocation.arguments["chief"] = .string(chief)
                }
            }
            _ = services?.registry.perform(ChiefInspectorHandlers.actionID, invocation: invocation)
        }
        settingsView.recents = services.chiefModelRecents
        // All Chief Settings…: Settings > Chief, the page with every Chief setting.
        settingsView.onAllSettings = { [weak self, weak services] in
            self?.settings.close()
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
        }
        settingsView.checkHarness = { [weak services] id in (try? await services?.agentHarnesses.doctor(id: id))?["ok"]?.boolValue == true }
        // Every harness this Mac's acpmux has (Settings > Agents' list), after the official engines.
        settingsView.listHarnesses = { [weak services] in (try? await services?.agentHarnesses.listed())?.sorted() ?? [] }
        settingsView.onRename = { [weak service] name in
            guard let service else { return .noConnection }
            // A cloud Chief's name is its account record's (UserDO renames its conversation after):
            // the local daemon has no such conversation, and the cloud refuses title.set on a Chief's.
            if service.isCloudConversation(id) { return await service.directory.renameChief(conversation: conversation, to: name) }
            // A Chief of this Mac: one set-title op; no daemon, or the daemon refusing it, says so on the card.
            guard let connection = service.connection else { return .noConnection }
            let key = "home-chief-rename-\(UUID().uuidString.lowercased())"
            do {
                _ = try await CmuxNextDaemon.ConversationClient(connection).op(
                    CmuxNextDaemon.ConversationOpRequest(conversation: conversation, idempotencyKey: key, transaction: nil, op: .setTitle(name)))
                return nil
            } catch CmuxNextDaemon.DaemonError.command(_, let message, let code, _, _) {
                return code == "invalid_title" ? .invalidName : .refused(message.isEmpty ? (code ?? "") : message)
            } catch {
                return .noConnection
            }
        }
        // The stop button (HomeHostView+StopAll): a click, Esc and Cmd-. stop the Chief; Option-click stops all agents.
        let registry = services.registry
        wireStopButton(registry)
        // A cmux app link (a workspace, pane, tab, chat or Chief subagent): opened here, through link.open.
        // An attachment or a path link opens in cmux on the right of Home, never in Finder (a
        // folder in a Files tab); right-click has Open With (HomeFileActions).
        let fileActions = HomeFileActions(services: services)
        self.fileActions = fileActions
        transcript.fileHost = fileActions
        transcript.onAppLink = { [weak services, weak fileActions] url in
            if url.isFileURL, url.path.hasPrefix("/") { fileActions?.open(URL(fileURLWithPath: url.path)); return }
            if let services { CmuxAppLinks.open(url, services: services) }
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
        // A Chief's cards (cmux issue 25830): Open browser selects the browser right of this chat (or a
        // Cloud machine's desktop); a sign-in card's Add saves into the Chief Secure Store.
        service.chiefCards.wire(transcript, host: services) { [weak self] url in
            if let self { LinkRouter.shared.open(url, otherTarget: false, from: self) } else { LinkRouter.shared.open(url, otherTarget: false) }
        }
        let store = service.homeStore
        // task-owner: lives as long as this view; event-driven (Observation):
        // whether this is the Chief conversation, and a refresh of the
        // settings' last turn on each new message.
        engineWatch = Task { [weak self] in
            for await (isChief, _, title, cloud, typing, named, hosted, participant) in ObservationStream({
                () -> (Bool, Int, String, Bool, Bool, String?, Bool, String?) in
                let row = store.rows.first { $0.summary.id == id }
                let chief = row?.summary.participants.contains { $0.agentClass == .chief } ?? false
                // A cloud Chief's brain runs on its paired server, never on
                // this Mac's mux home (2026-10-08: the sidebar wrote codex
                // here while cmux-lawrence ran claude-sr).
                return (chief, store.transcriptVersion[id] ?? 0, row?.summary.title ?? "", service.isCloudConversation(id),
                        row?.isTyping ?? false, row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) },
                        service.cloudChiefPlacement(of: conversation)?.placed != true,
                        row.flatMap { HomeService.soleChief(of: $0.summary.participants) })
            }) {
                guard let self else { return }
                // A named Chief's conversation: its panel, Stop and avatar name it (cx-327wl).
                if named != control.chief {
                    control.chief = named
                    settingsView.use(control.engineSource())
                    loadAvatar()
                }
                // The popover's characters are this Chief's own (a new one redraws the header).
                petRows.chief = participant
                self.isChief = isChief
                openPendingSettings()
                // The Chief types while its turn runs: the compose bar offers Stop.
                isWorking = isChief && typing
                transcript.isWorking = isWorking
                if cloud != showsCloud || (cloud && hosted != showsHosted) {
                    showsCloud = cloud
                    showsHosted = hosted
                    settingsView.use(control.engineSource())
                }
                settingsView.setName(title)
                if !isChief, settings.isShown { settings.close() }
                if settings.isShown { settingsView.refresh() }
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation): each Chief of
        // this conversation wears its Home row's avatar beside a group's bubbles, again after a
        // swap (a Chief's picture or text, the pet character a Chief with none wears).
        avatarsWatch = Task { [weak self, weak service, weak services] in
            for await avatars in ObservationStream({ () -> [String: HomeChiefAvatar] in
                guard let service else { return [:] }
                let participants = store.rows.first { $0.summary.id == id }?.summary.participants ?? []
                let fallback = HomeHostView.defaultTileAvatar(picture: services?.characterPicture(of: nil))
                return HomeChiefAvatar.bubbleAvatars(for: participants, own: service.chiefFaces, fallback: fallback)
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
        transcript.onFirstRunAction = { [weak self] action in
            let id: ActionID = switch action {
            case .openTerminal: Self.openTerminalAction
            case .startAgent: Self.startAgentAction
            case .togglePet: "home.toggleChiefPet"
            case .importMemories: ChiefMemoryImportHandlers.actionID
            }
            if action == .importMemories {
                // The offer is used up by the click: the panel shows it once.
                UserDefaults.standard.set(true, forKey: Self.memoryOfferUsedKey)
                self?.transcript.setFirstRunMemoryOffer(nil)
            }
            _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
        }
        // Onboarding: the Chief's front page (no messages yet) offers to bring memory from the other tools found on
        // this Mac. One read off the main thread; nothing found, nothing shown, and a used offer never returns.
        let muxHome = HomeBrainHost.muxHome(tag: services.environment.tag).path
        memoryOfferWatch = Task { [weak self] in
            guard !UserDefaults.standard.bool(forKey: Self.memoryOfferUsedKey) else { return }
            let sources = await ChiefMemoryImportHandlers.detectForOffer(muxHome: muxHome)
            guard !Task.isCancelled, !service.isCloudConversation(id), let title = MemorySource.offerTitle(sources),
                  let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                  summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return }
            self?.transcript.setFirstRunMemoryOffer(title)
        }
        // The first-run panel's agent rows open the agent's tab like a jump (Search Tabs).
        transcript.onFirstRunAgent = { [weak services] tab in _ = services?.revealTab(tab) }
        // task-owner: lives as long as this view; event-driven (Observation):
        // the user's agents for the first-run glance, only while it can show
        // (the Chief with no messages yet): otherwise no tab is read, so tab
        // changes never wake a Chief with history.
        agentsWatch = Task { [weak self] in
            for await state in ObservationStream({ () -> ([HomeAgentGlance], HomeStarterContext)? in
                guard let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                      summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return nil }
                let glances = HomeAgentGlances(services: services)
                let agents = glances.current
                return (agents, glances.starters(agents: agents, badges: SidebarSessionTree.shared.pullRequests))
            }) {
                guard let state else { continue }
                self?.transcript.setFirstRunAgents(state.0)
                self?.transcript.setFirstRunStarters(state.1)
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
        let reveal = services.launchReveal
        // task-owner: lives as long as this view; ends when the first page is in
        firstPage = Task { [weak self] in
            await binding.opened()
            // A Home released before its page came (deinit cancels this) must not
            // reveal the Home that replaced it, which waits for its own page.
            guard let self, !Task.isCancelled else { return }
            transcript.holdsFirstRun = false
            // A launch holds a Home still being made until here (WorkspaceContentController).
            reveal.markReady(.home)
        }
        wantsLayer = true
        clipsToBounds = true
        message.alignment = .center
        // A long reason (a migration notice) wraps in a narrow pane instead of clipping.
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.wraps = true
        message.stringValue = HomeStrings.unavailable
        // Hidden until the owner answers: a daemon still connecting is not one too old (the launch's fill shows).
        message.isHidden = true
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
                self?.transcript.isHidden = !available
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
        for task in [availability, engineWatch, avatarsWatch, hostWatch, agentsWatch, shortcutsWatch, spellCheckingWatch, headerPanelsWatch, firstPage, memoryOfferWatch] {
            task?.cancel()
        }
        let settings = settings, transcript = transcript
        // task-owner: the main-actor half of this view's release; one call each, then it ends
        Task { @MainActor in
            settings.close()
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

    /// The name pill's click (or `home.toggleChiefSettings`): the Chief's settings open under the pill, or
    /// close again (never with `openOnly`, the pet's Chief Pet Settings…). Only over the Chief. True if shown.
    @discardableResult func toggleChiefSettings(openOnly: Bool = false) -> Bool {
        if settings.isShown { if !openOnly { settings.close() }; return openOnly }
        guard isChief, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        settingsView.refresh()
        return settings.show(relativeTo: transcript.namePill, toggles: transcript.namePillToggles)
    }

    /// The popover is a child panel of the window, not a subview: Home leaving
    /// its window (a tab or workspace switch, Cmd-W) or hiding closes it, so it
    /// never stays over the next pane.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window { settings.close() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        openPendingSettings()
        watchHeaderPanels()
    }

    override func viewDidHide() {
        super.viewDidHide()
        settings.close()
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

    /// The picture of the pet character the Chief shown here wears (its own pick).
    private var characterPicture: URL? {
        control.services.characterPicture(of: petRows.chief)
    }

    /// The header avatar of the Chief shown here: its registry picture, else its profile's text,
    /// else its own pet character.
    private func loadAvatar() {
        let home = control.brainHome
        let files = HomeChiefFiles(muxHome: home)
        let store = pictureStore()
        settingsView.pictureStore = store
        let fallback = characterPicture
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
                  fallback == characterPicture else { return }
            let picture = decoded.map { NSImage(cgImage: $0, size: .zero) }
            let text = HomeChiefAvatar.headerText(avatar.text, hasPicture: picture != nil)
            transcript.setChiefAvatar(picture: picture, text: text)  // the header and the first-run hero
            settingsView.setAvatar(picture: picture, text: text)
        }
    }

    /// The first frame of the picture `data` holds, decoded now.
    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
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
