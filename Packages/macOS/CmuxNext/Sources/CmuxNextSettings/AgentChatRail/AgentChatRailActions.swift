public import CmuxNextActions
import CmuxNextDesign
import os

/// The palette's cmux.json toggles that are one key each: Show Chat Minimap and Prompt Rail on Right Edge
/// (``AgentChatRailActionCatalog``; the user, 2026-11-03, msg 20105), and Match Terminal Background
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
    /// Match Terminal Background.
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
        toggle(Self.showMinimap, Self.minimapPath, in: registry, isOn: { Self.isMinimapShown(Self.display($0)) }) { on in
            on ? nil : .string("off")
        }
        toggle(Self.railOnRight, Self.railSidePath, in: registry, isOn: { Self.isRailOnRight(Self.display($0)) }) { on in
            on ? .string("right") : nil
        }
        toggle(Self.matchTerminalBackground, SidebarSurfaceSetting.configPath, in: registry,
               isOn: { $0.map { SidebarSurfaceSetting.effective(in: $0.snapshot) == .same } ?? false }) { on in
            .string((on ? SidebarSurface.same : .separate).rawValue)
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

    /// Binds `id` to flip its state and write `value(on)` at `path` (nil removes the key), and its palette
    /// state to `isOn`. The write lands after the run returns: until it does, the palette row reads the
    /// state the run asked for, and the open palette reads its rows again once it lands or fails
    /// (`ActionRegistry.paletteStateDidChange`), as a Settings row does (`SettingsPaletteSource`). A run
    /// before an earlier write landed flips from the state that write asked for, and the writes land in
    /// order, so two quick runs end where they started.
    private func toggle(_ id: ActionID, _ path: [String], in registry: ActionRegistry,
                        isOn: @escaping @MainActor (SettingsController?) -> Bool,
                        value: @escaping @MainActor (Bool) -> JSONValue?) {
        let (settings, managed, notLoaded, logger) = (settings, managed, notLoaded, Self.logger)
        // The registry keeps these closures and with them this object (the App binds one and drops it).
        registry.bindEffect(id) { [weak registry] invocation in
            guard let settings = settings() else { return .refused(notLoaded) }
            if let key = settings.managedKey(forPath: path)?.key { return .refused(managed(key)) }
            let on = !(self.pending[id]?.isOn ?? isOn(settings)), writer = SettingWriter(invocation.origin)
            let token = self.markPending(id, on)
            let earlier = self.writing[id]
            // task-owner: one settings write, after this row's earlier one; ends when cmux.json is written
            let write = Task {
                await earlier?.value
                do { try await settings.setSetting(at: path, to: value(on), by: writer) } catch {
                    logger.error("palette setting toggle failed: \(String(describing: error), privacy: .public)")
                }
            }
            self.writing[id] = write
            Task {
                await write.value
                guard self.pending[id]?.token == token else { return }
                self.writing[id] = nil
                self.pending[id] = nil
                registry?.paletteStateDidChange?()
            }
            return .done
        }
        let state: @MainActor () -> Bool = { [settings] in self.pending[id]?.isOn ?? isOn(settings()) }
        ActionTargetTitles.setPaletteSettingState(id, in: registry, state)
    }

    /// The state each row's write asked for while it has not landed, with that write's token.
    private var pending: [ActionID: (token: Int, isOn: Bool)] = [:]
    private var writes = 0
    /// Each row's last write, which its next one waits for.
    private var writing: [ActionID: Task<Void, Never>] = [:]

    private func markPending(_ id: ActionID, _ isOn: Bool) -> Int {
        writes += 1
        pending[id] = (writes, isOn)
        return writes
    }
}
