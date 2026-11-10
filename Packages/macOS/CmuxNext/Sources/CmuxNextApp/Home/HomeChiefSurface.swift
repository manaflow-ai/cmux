import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefPetWiring
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextHostedChief
import CmuxNextSettings
import CmuxNextWakeups
import ImageIO

/// A Home view that may show a Chief: a conversation tab or the Chief panel (``HomeConversationPage``)
/// and the docked Messages page (``HomeMessagesPage``). `home.stopChief`, `home.stopAllAgents` and
/// `home.toggleChiefSettings` act on the front window's (``HomeChiefActions``).
@MainActor
protocol HomeChiefShowing: NSView {
    /// The Chief this view shows on screen now, with its controls; nil when it shows none.
    var shownChief: HomeChiefSurface? { get }
}

/// What a Home view does for the Chief conversation it shows, apart from drawing it (the Messages
/// page draws it): the Chief's settings, a popover under the page's name pill; Stop, Stop All Agents
/// and their toast; whether the Chief answers now (the Chief panel's Esc). Moved from the native
/// `HomeHostView`, unchanged: the popover, its rows and its hooks are the same objects.
@MainActor
final class HomeChiefSurface {
    let conversation: ConversationID
    /// Which brain answers this conversation (this Mac's or a paired server's).
    private(set) var control: HomeChiefControl
    /// The Chief's stop and stop-all, one request at a time.
    let turnActions = HomeChiefTurnActions()
    private(set) var isChief = false
    /// The Chief's participant id (its picked character is its own).
    private var participant: String?
    /// The header's avatar was read (`picture`: a PNG data URL; `text`: the profile's text; both nil:
    /// its name's monogram), for the page to draw.
    var onFace: ((_ picture: String?, _ text: String?) -> Void)?
    private(set) var isWorking = false
    private weak var services: AppServices?
    /// The view the popover's anchor lies in (the page).
    private weak var owner: NSView?
    /// A transparent view over the page's name pill: the popover opens under it.
    private let anchor = HomeChiefSettingsAnchor()
    /// Made on the first open: a Chief whose settings never open builds none of it.
    private var made: Made?
    /// The engine source shows a cloud Chief's brain, and whether the Cloud service hosts it.
    private var showsCloud = false
    private var showsHosted = false
    private var engineWatch: Task<Void, Never>?
    private var hostWatch: Task<Void, Never>?

    private struct Made {
        let settings: HomeChiefSettingsPopover
        let petRows: ChiefPetSettingsRows
        let teleport: ChiefTeleportChips
        var view: HomeChiefSettingsView { settings.content }
    }

    init(services: AppServices, conversation: ConversationID, owner: NSView) {
        self.services = services
        self.conversation = conversation
        self.owner = owner
        control = HomeChiefControl(services: services, conversation: conversation,
                                   muxHome: HomeBrainHost.muxHome(tag: services.environment.tag))
        watchEngine(services.home)
    }

    nonisolated deinit {
        engineWatch?.cancel()
        hostWatch?.cancel()
    }

    /// The view left its window or hid: the popover closes, so it never stays over the next pane.
    func close() {
        made?.settings.close()
    }

    /// This surface's Chief shows in its view, on screen.
    var showsChiefOnScreen: Bool {
        guard isChief, let owner else { return false }
        return owner.window != nil && !owner.isHiddenOrHasHiddenAncestor
    }

    // MARK: Watching the conversation

    private func watchEngine(_ service: HomeService) {
        let store = service.homeStore
        let id = conversation
        // task-owner: lives as long as this surface (cancelled in deinit); event-driven (Observation):
        // whether this is a Chief conversation, its named Chief, whether it answers, and the
        // settings' name and engine source.
        engineWatch = Task { [weak self] in
            for await (isChief, title, cloud, typing, named, hosted, participant, lastSeq) in ObservationStream({
                () -> (Bool, String, Bool, Bool, String?, Bool, String?, Seq) in
                let row = store.rows.first { $0.summary.id == id }
                let chief = row?.summary.participants.contains { $0.agentClass == .chief } ?? false
                // The Chief's own name (HomeService.chiefName(of:)), the one its tile and tab show.
                let name = service.chiefName(of: id)
                return (chief, name ?? row?.summary.title ?? "", service.isCloudConversation(id), row?.isTyping ?? false,
                        row.flatMap { ChiefHome.namedChief(in: $0.summary.participants) },
                        service.cloudChiefPlacement(of: id.rawValue)?.placed != true,
                        row.flatMap { HomeService.soleChief(of: $0.summary.participants) }, row?.summary.lastSeq ?? 0)
            }) {
                guard let self else { return }
                // A named Chief's conversation: its panel, Stop and avatar name it (cx-327wl).
                let renamed = named != control.chief
                if renamed { control.chief = named }
                let reread = renamed || isChief != self.isChief || participant != self.participant
                (self.isChief, self.participant) = (isChief, participant)
                isWorking = isChief && typing
                turnActions.update(control: control.turnControl, isChief: isChief, working: isWorking, sequence: lastSeq)
                let engineMoved = cloud != showsCloud || (cloud && hosted != showsHosted)
                (showsCloud, showsHosted) = (cloud, hosted)
                if let made {
                    made.petRows.chief = participant  // the popover's characters are this Chief's own
                    if renamed || engineMoved { made.view.use(control.engineSource()) }
                    made.view.setName(title)
                    if !isChief, made.settings.isShown { made.settings.close() }
                    if made.settings.isShown { made.view.refresh() }
                }
                if reread { loadAvatar() }
                openPendingSettings()
            }
        }
    }

    // MARK: Settings

    /// The name pill's click (`cmux.home.messages.chief.settings`, or `home.toggleChiefSettings`):
    /// the Chief's settings open under `pill` (page points from the owner's top-left; nil: where it
    /// last was), or close again (never with `openOnly`, the pet's Chief Pet Settings…). True if shown.
    @discardableResult
    func toggleSettings(under pill: CGRect? = nil, openOnly: Bool = false) -> Bool {
        let made = make()
        if made.settings.isShown {
            if !openOnly { made.settings.close() }
            return openOnly
        }
        guard showsChiefOnScreen, let owner else { return false }
        let placed = anchor.superview === owner
        if !placed { owner.addSubview(anchor) }
        if let pill {
            anchor.frame = HomeChiefSettingsAnchor.frame(of: pill, in: owner)
        } else if !placed {  // opened by the action before any click: under the header's pill, top centre
            anchor.frame = HomeChiefSettingsAnchor.frame(of: CGRect(x: owner.bounds.midX - 60, y: 46, width: 120, height: 24), in: owner)
        }
        made.view.refresh()
        return made.settings.show(relativeTo: anchor, toggles: [anchor])
    }

    /// The header's location chip was clicked at `chip` (page points): the Teleport menu pops up under it.
    func openTeleportMenu(under chip: CGRect) {
        guard showsChiefOnScreen, let owner else { return }
        control.services.chiefTeleport.openMenu(under: HomeChiefSettingsAnchor.frame(of: chip, in: owner), in: owner)
    }

    /// Opens the settings `HomeChiefActions` asked for once this view shows its Chief (Toggle Chief
    /// Settings with no Home in front brought Home forward at this conversation).
    func openPendingSettings() {
        guard let home = services?.home, showsChiefOnScreen, home.pendingChiefSettings == conversation else { return }
        home.pendingChiefSettings = nil
        toggleSettings(openOnly: true)
    }

    private func make() -> Made {
        if let made { return made }
        let control = control
        let services: AppServices? = control.services
        let conversation = conversation.rawValue
        let view = HomeChiefSettingsView(muxHome: control.brainHome, source: control.engineSource())
        let settings = HomeChiefSettingsPopover(content: view)
        let app = control.services
        let petRows = ChiefPetSettingsRows(settings: { [weak app] in app?.settings }, homes: app.chiefPetHomes,
                                           picks: app.chiefMascotPicks, uploads: app.chiefAvatarUploads)
        let teleport = ChiefTeleportChips(model: app.chiefTeleport)
        let made = Made(settings: settings, petRows: petRows, teleport: teleport)
        self.made = made
        let service: HomeService? = app.home
        petRows.onMascot = { [weak self] in self?.loadAvatar() }  // a new character redraws the card at once
        petRows.onRefusal = { [view] in view.showNote($0) }  // why an upload was refused
        petRows.install(in: owner ?? anchor, addRow: { [view] in view.addAppearanceRow($0, control: $1) },
                        open: { [weak self] in self?.toggleSettings(openOnly: true) ?? false })
        view.onAvatar = { [weak self, weak service] in
            self?.loadAvatar()
            // Each Chief's tile reads its own brain home: this re-reads them, so only the
            // Chief whose picture changed draws differently (cx-327wl).
            service?.refreshChiefAvatars()
        }
        // A new engine of this Chief: the Home list's badge follows it.
        view.onEngineChanged = { [weak service] in service?.refreshChiefHarnesses() }
        // The card's "Switch to …": the same Chief on its other host takes the Chief tab.
        view.onSwitchHost = { [weak service] in
            guard let service, let other = service.tabChiefs.otherHost(of: conversation) else { return }
            service.hostedChief.pick(other)
        }
        // task-owner: lives as long as this surface (cancelled in deinit); event-driven (Observation)
        hostWatch = Task { [weak view, weak service] in
            for await host in ObservationStream({ service?.chiefHost(of: conversation) ?? HomeChiefHostLine() }) {
                view?.setHost(place: host.place, switchTo: host.switchTo)
            }
        }
        // Show Memory: this conversation's Chief (a named local Chief, or a cloud Chief's paired server).
        view.onShowMemory = { [weak self, weak services] in
            var invocation = ActionInvocation(origin: .user)
            guard let control = self?.control else { return }
            if let machine = control.server?.machineID {
                invocation.arguments["server"] = .string(machine)
            } else if let chief = control.named {
                invocation.arguments["chief"] = .string(chief)
            }
            _ = services?.registry.perform(ChiefInspectorHandlers.actionID, invocation: invocation)
        }
        view.recents = app.chiefModelRecents
        // All Chief Settings…: Settings > Chief, the page with every Chief setting.
        view.onAllSettings = { [weak settings, weak services] in
            settings?.close()
            try? services?.settingsWindow.show(section: nil, focus: true, route: "#/settings/chief")
        }
        view.checkHarness = { [weak services] id in (try? await services?.agentHarnesses.doctor(id: id))?["ok"]?.boolValue == true }
        // Every harness this Mac's acpmux has (Settings > Agents' list), after the official engines.
        view.listHarnesses = { [weak services] in (try? await services?.agentHarnesses.listed())?.sorted() ?? [] }
        // One rename path for every Chief (HomeService.renameChief): every surface shows the new name at once.
        view.onRename = { [weak service] name in
            await service?.renameChief(conversation: conversation, to: name) ?? .noConnection
        }
        if let service { view.bindPrimary(directory: service.directory, conversation: conversation) }  // the Primary Chief row
        // The card's Runs On row, on the Chief that `cmux chief move` moves.
        teleport.follow(for: anchor, { [weak service] in service?.showsTeleport(conversation: conversation) ?? false }) { [weak view] _, card in
            view?.showTeleport(card)
        }
        if let service, let row = service.homeStore.rows.first(where: { $0.summary.id == self.conversation }) {
            petRows.chief = HomeService.soleChief(of: row.summary.participants)
            view.setName(service.chiefName(of: self.conversation) ?? row.summary.title)
        }
        loadAvatar()
        return made
    }

    // MARK: Avatar

    /// Where this Chief's picture is kept: the daemon's Chief registry for a Chief of this Mac
    /// (the store the profile and chiefs tools write); nil for a cloud Chief (its files).
    private func pictureStore() -> (avatars: HomeChiefAvatars, chief: String)? {
        guard !control.isCloud else { return nil }
        let avatars = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: control.services.environment.tag),
                                       registry: DaemonChiefAvatarRegistry(connection: control.connection))
        return (avatars, HomeChiefAvatars.chiefID(named: control.named))
    }

    /// The avatar of the Chief shown here, on the page's header and the card: its registry picture,
    /// else its profile's text, else its worn upload, else its name's monogram.
    private func loadAvatar() {
        guard isChief else { return }
        let home = control.brainHome
        let files = HomeChiefFiles(muxHome: home)
        let store = pictureStore()
        made?.view.pictureStore = store
        let fallback = control.services.chosenPicture(of: participant)
        // task-owner: one avatar read (registry, else files off the main actor); ends when it is shown
        Task { [weak self] in
            let avatar = if let store {
                await store.avatars.headerAvatar(chief: store.chief, fallback: fallback)
            } else {
                await HomeChiefAvatars.headerAvatar(files: files, fallback: fallback)
            }
            // task-owner: one decode of the avatar picture; ends when it is shown
            let decoded = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) { avatar.picture.flatMap(HomeChiefAvatars.firstFrame) }.value
            let page = if let data = avatar.picture { await HomeChiefAvatars.pagePicture(data) } else { String?.none }
            // A read for the Chief shown before (another came in since) is dropped.
            guard let self, control.brainHome == home else { return }
            onFace?(page, avatar.text)
            let name = control.services.home.chiefName(of: conversation) ?? ""
            made?.view.setAvatar(picture: decoded.map { NSImage(cgImage: $0, size: .zero) }, text: avatar.text ?? HomeChiefAvatar.monogram(of: name))
        }
    }

    // MARK: Stop

    /// `chief.stop {all}` on this Chief, then the toast: what stopped, with Restart when subagents
    /// did. A failure, or no Chief shown (or a hosted cloud Chief, which has no stop), beeps.
    func stopAllAgents() {
        let control = control
        guard showsChiefOnScreen, !control.isHosted, let window = owner?.window else { return NSSound.beep() }
        // task-owner: one chief.stop {all}, then the toast; ends with the answer
        // main-hop-allow: already on main (a click); the task only awaits one daemon answer, then shows one toast
        Task { @MainActor [weak window, turnActions] in
            switch await turnActions.stopAll() {
            case .failure:
                NSSound.beep()
            case .success(let answer):
                guard let window else { return }
                let names = answer.subagents
                let handle = CmuxToastCenter.shared.show(.stopAll(answer), in: window)
                handle.onAction = {
                    // task-owner: one chief.stop {restart}; ends with its answer
                    Task { @MainActor in if await control.restart(names) != nil { NSSound.beep() } }
                }
            }
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.home.api` edit_picture: a picture picked or dropped on this Chief's card (Move and Scale).
    func debugEditPicture(_ source: URL, zoom: CGFloat?, save: Bool) async -> Bool? {
        let view = make().view
        loadAvatar()
        return await view.debugEditPicture(source, zoom: zoom, save: save)
    }

    /// `debug.home.drive` chief_name (the native HomeHostView's, d6a68ad3): the settings open with the keyboard in
    /// the name field, as a click does; `close` closes them, as a click outside does.
    func debugEditName(close: Bool) -> Bool {
        if close { self.close(); return true }
        return toggleSettings(openOnly: true) && make().view.beginEditingName()
    }
    #endif
}

extension CmuxToast {
    /// The Stop all agents toast for the daemon's answer: what stopped, how many could not be
    /// stopped (which and why in its tooltip), the note about any still starting, and Restart
    /// when subagents stopped (never for one that could not be stopped).
    static func stopAll(_ answer: ChiefStopAll, duration: Duration = .seconds(6)) -> CmuxToast {
        let action = answer.subagents.isEmpty ? nil : CmuxToast.Action(title: HomeStopAllStrings.restart)
        return CmuxToast(id: "home.stopAllAgents", message: HomeStopAllStrings.message(for: answer),
                         detail: HomeStopAllStrings.detail(for: answer), action: action, duration: duration)
    }

    /// The toast for an answer's JSON, decoded as the daemon's answer is (`debug.toast {stop_all}`).
    static func stopAll(decoding answer: Data, duration: Duration = .seconds(6)) throws -> CmuxToast {
        stopAll(try JSONDecoder().decode(ChiefStopAll.self, from: answer), duration: duration)
    }
}
