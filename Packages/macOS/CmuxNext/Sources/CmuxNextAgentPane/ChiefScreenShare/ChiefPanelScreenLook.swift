public import CmuxNextDictation
public import CmuxNextSettings

/// The floating Chief's "sees your screen" eye (`home.chiefPanel.seesScreen`, user 2026-11-07): whether it is on,
/// its click, and the one look at the screen when the panel opens (``ChiefScreenShare/glance(app:window:)``,
/// through Share Screen with Chief's helper and its Screen Recording grant, never a prompt). The look happens only
/// while Computer Use is on (`computerUse.enabled`): its helper then runs by the person's choice, and opening the
/// panel never starts it.
///
/// ```swift
/// let look = ChiefPanelScreenLook(share: { [weak services] in services?.chiefScreenShare }, settings: { services.settings })
/// panel.actions.toggleSeesScreen = look.toggle
/// ```
@MainActor
public struct ChiefPanelScreenLook {
    private let share: @MainActor () -> ChiefScreenShare?
    private let settings: @MainActor () -> SettingsController?

    /// - Parameters:
    ///   - share: The app's Share Screen with Chief model, which reads the screen; asked for only when a look happens.
    ///   - settings: The settings the eye reads and writes; nil before they load.
    public init(share: @escaping @MainActor () -> ChiefScreenShare?, settings: @escaping @MainActor () -> SettingsController?) {
        self.share = share
        self.settings = settings
    }

    /// Whether opening the panel gives the Chief a look (on when unset).
    public var seesScreen: Bool { settings()?.snapshot.chiefPanelSeesScreen ?? ChiefDockSetting.seesScreenDefault }

    /// The eye's click: turns the setting off or on, as a person's write.
    public func toggle() {
        let on = !seesScreen, settings = settings()
        // task-owner: one settings write per click; the panel follows the setting when it lands.
        Task { try? await settings?.setSetting(at: ChiefDockSetting.seesScreenPath, to: .bool(on), by: .user) }
    }

    /// The panel opened in a cmux window titled `window`: with the eye and Computer Use on, one look at the screen,
    /// kept for the Chief's next turn.
    public func panelOpened(window: String?) {
        // Computer Use off, a look would start its helper (or wait on a gone one) at every open.
        guard seesScreen, settings()?.snapshot.computerUse.enabled == true, let share = share() else { return }
        // task-owner: one look per open; the share model owns the capture and the journal.
        Task { _ = await share.glance(app: "cmux", window: window) }
    }
}
