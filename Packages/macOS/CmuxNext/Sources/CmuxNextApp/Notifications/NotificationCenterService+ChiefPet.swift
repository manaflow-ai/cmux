import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextChiefPetWiring
import CmuxNextDaemon
import CmuxNextDesignTokens
import CmuxNextFloating
import CmuxNextSettings

/// The Chief pet (`CmuxNextFloating`): this service makes it, follows `home.chiefPetEnabled` and
/// `home.chiefPetMascot`, and feeds it what alerts here and which tabs were read.
extension NotificationCenterService {
    /// Showcase captures draw the app's own windows only, so they never start the pet.
    func followChiefPet(_ settings: SettingsController) {
        guard desktopPostingEnabled, let services, chiefPet == nil else { return }
        let pet = ChiefPetRoutes(services: services).makePet()
        chiefPet = pet
        pet.start(enabled: { [weak settings] in settings?.snapshot.homeChiefPetEnabled ?? false },
                  mascot: { [weak settings] in settings?.snapshot.homeChiefPetMascot ?? "" },
                  upload: { [weak services] in services?.wornUpload(of: nil)?.file },
                  state: { Self.chiefPetState(ChiefSidebar.shared.status.activity) })
    }

    /// The Chief's sidebar status as the pet draws it: working, waiting on you, failed, else idle.
    nonisolated static func chiefPetState(_ activity: StatusIndicatorState) -> ChiefPetState {
        switch activity {
        case .working, .busy: .working
        case .waiting: .waiting
        case .error: .error
        case .idle, .paused, .success: .idle
        }
    }

    /// An arrival that stays unread goes to the Chief pet when it would alert here, by a banner's
    /// rules (muted workspaces, quiet hours, `notifications.desktop`) whether or not its poster asked for one.
    func notifyChiefPet(_ notification: DaemonNotification, located: LocatedTab, decision: NotificationPolicy.Decision, program: ProgramStatusNotification?) {
        // Off, the pet takes nothing: no notice is built (the body reads whether the screen is locked).
        guard decision.alerts, let chiefPet, chiefPet.isOn else { return }
        chiefPet.arrive(ChiefPetNotice(notification, tab: located.tab, name: shownName(of: located.tab), workspace: located.workspace.displayName,
                                            programTitle: program?.title(localizations: localizations),
                                            body: notification.bannerBody(previews: previews, screenLocked: screenLocked())))
    }

    /// A tab read anywhere else (another client, the phone, a closed tab, a daemon restart) leaves the pet too.
    func dropReadChiefPetNotices() {
        guard let chiefPet, let store = services?.daemon.store else { return }
        chiefPet.keepNotices { Self.tab(id: $0, in: store)?.hasUnread == true }
    }

    /// The pet's typed reply to `notice`, only while it is still its tab's unread notification, as a
    /// `notify --reply` banner's is (a notice read meanwhile must not type into whatever runs there
    /// now), and only while a program still runs in the foreground there: with the agent gone and its
    /// shell back, the text and Return would run as a command (``DaemonConnection/typeToForegroundProgram(_:text:)``).
    func typeChiefPetReply(_ text: String, to notice: ChiefPetNotice) async -> Bool {
        guard let services, !text.isEmpty, notice.reply == .type, let surface = notice.surface,
              let located = locate(surface: SurfaceID(rawValue: surface), in: services.daemon.store), located.tab.kind == .pty,
              let marker = located.tab.notification, marker.unread, marker.notification.rawValue == notice.id else {
            note("pet reply refused: notice \(notice.id) is not its tab's unread notification")
            return false
        }
        let target = located.tab.surface
        let daemon = services.daemon(for: located.pane)
        // An older daemon ignores `expect_foreground`: the reply still goes, checked one round trip early.
        let guarded = daemon.supports(DaemonCapability.sendExpectForeground.rawValue)
        let failed = await daemon.failure("chief-pet-reply") { try await $0.typeToForegroundProgram(target, text: text) }
        guard failed == nil else {
            note("pet reply refused: only a shell runs in \(located.tab.id), or the daemon refused")
            return false
        }
        note("pet reply \(located.tab.id)\(guarded ? "" : " (unguarded: the daemon lacks send-expect-foreground-v1)")")
        acknowledge(located.tab)
        return true
    }

    /// Pastes `text` into `located`'s terminal, then Return as its own key, on the tab's own machine (a
    /// Cloud terminal's input goes over its link): a reply answered the tab, so it is read. False for a non-terminal.
    @discardableResult
    func type(_ text: String, into located: LocatedTab) -> Bool {
        guard let services, !text.isEmpty, located.tab.kind == .pty else { return false }
        let target = located.tab.surface
        services.daemon(for: located.pane).send("notification-reply") { connection in
            try await connection.send(target, text: text, paste: true)
            try await connection.send(target, text: "\r")
        }
        note("reply \(located.tab.id)")
        acknowledge(located.tab)
        return true
    }
}
