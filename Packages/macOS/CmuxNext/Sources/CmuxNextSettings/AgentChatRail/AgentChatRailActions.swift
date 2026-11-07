public import CmuxNextActions
import CmuxNextDesign
import os

/// The palette's cmux.json toggles that are one key each: Show Chat Minimap and Prompt Rail on Right Edge
/// (``AgentChatRailActionCatalog``; the user, 2026-11-03, msg 20105), and Toggle Match Terminal Background
/// (`palette.toggleMatchTerminalBackground`, `cmux sidebar toggle-match-terminal-background`).
///
/// Each row writes its key through the validated settings path, so Settings and every view that follows
/// the key change with it, and a managed key refuses. Each row is checked in the palette while on:
/// Show Chat Minimap writes `agentPane.display.minimap` `off` and removes it again (the rail, the row's
/// default); Prompt Rail on Right Edge writes `agentPane.display.rail.side` `right` and removes it again
/// (left). Match Terminal Background flips `appearance.sidebarSurface` between `same` and `separate`.
///
/// ```swift
/// AgentChatRailActions(settings: { services.settings }, managed: RefusalStrings.settingManaged,
///                      notLoaded: RefusalStrings.settingsNotLoaded).bind(into: registry)
/// ```
@MainActor
public final class AgentChatRailActions {
    /// Show Chat Minimap.
    public static let showMinimap: ActionID = "agentPane.display.showMinimap"
    /// Prompt Rail on Right Edge.
    public static let railOnRight: ActionID = "agentPane.display.railOnRight"
    /// Toggle Match Terminal Background.
    public static let matchTerminalBackground: ActionID = "palette.toggleMatchTerminalBackground"
    static let minimapPath = ["agentPane", "display", "minimap"]
    static let railSidePath = ["agentPane", "display", "rail", "side"]
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    private let settings: @MainActor () -> SettingsController?
    private let managed: @MainActor (String) -> String
    private let notLoaded: String

    /// - Parameters:
    ///   - settings: The app's settings, nil before they load (the rows read the defaults and refuse to write).
    ///   - managed: The refusal for a managed key, given the key.
    ///   - notLoaded: The refusal before the settings load.
    public init(settings: @escaping @MainActor () -> SettingsController?, managed: @escaping @MainActor (String) -> String,
                notLoaded: String) {
        self.settings = settings
        self.managed = managed
        self.notLoaded = notLoaded
    }

    /// Binds the three rows and their palette checks into `registry`.
    public func bind(into registry: ActionRegistry) {
        toggle(Self.showMinimap, Self.minimapPath, in: registry) { settings in
            Self.isMinimapShown(Self.display(settings)) ? .string("off") : nil
        }
        ActionTargetTitles.setPaletteState(Self.showMinimap, in: registry) { [settings] in Self.isMinimapShown(Self.display(settings())) }
        toggle(Self.railOnRight, Self.railSidePath, in: registry) { settings in
            Self.isRailOnRight(Self.display(settings)) ? nil : .string("right")
        }
        ActionTargetTitles.setPaletteState(Self.railOnRight, in: registry) { [settings] in Self.isRailOnRight(Self.display(settings())) }
        toggle(Self.matchTerminalBackground, SidebarSurfaceSetting.configPath, in: registry) { settings in
            .string((SidebarSurfaceSetting.effective(in: settings.snapshot) == .same ? SidebarSurface.separate : .same).rawValue)
        }
        ActionTargetTitles.setPaletteState(Self.matchTerminalBackground, in: registry) { [settings] in
            settings().map { SidebarSurfaceSetting.effective(in: $0.snapshot) == .same } ?? false
        }
    }

    /// The chat's edge shows the rail or the full map (`agentPane.display.minimap` is not `off`).
    static func isMinimapShown(_ display: AgentPaneDisplaySetting) -> Bool {
        display.values["agentPane.display.minimap"] != .string("off")
    }

    /// The rail sits on the chat's right edge (`agentPane.display.rail.side` is `right`).
    static func isRailOnRight(_ display: AgentPaneDisplaySetting) -> Bool {
        display.values["agentPane.display.rail.side"] == .string("right")
    }

    private static func display(_ settings: SettingsController?) -> AgentPaneDisplaySetting {
        settings.map { AgentPaneDisplaySetting(fileRoot: $0.fileRoot) } ?? .fallback
    }

    /// Binds `id` to write `next(settings)` at `path` (nil removes the key).
    private func toggle(_ id: ActionID, _ path: [String], in registry: ActionRegistry,
                        next: @escaping @MainActor (SettingsController) -> JSONValue?) {
        let (settings, managed, notLoaded, logger) = (settings, managed, notLoaded, Self.logger)
        registry.bindEffect(id) { invocation in
            guard let settings = settings() else { return .refused(notLoaded) }
            if let key = settings.managedKey(forPath: path)?.key { return .refused(managed(key)) }
            let value = next(settings), writer = SettingWriter(invocation.origin)
            // task-owner: one settings write; ends when cmux.json is written
            Task {
                do { try await settings.setSetting(at: path, to: value, by: writer) } catch {
                    logger.error("palette setting toggle failed: \(String(describing: error), privacy: .public)")
                }
            }
            return .done
        }
    }
}
