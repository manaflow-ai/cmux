import AppKit
public import CmuxNextActions
public import CmuxNextSettings
import CmuxNextSettingsWindow
public import CmuxNextSidebar

/// Command Palette "Density Lab" (`debug.densityLab`, DEV and NIGHTLY; Lawrence 2026-11-12: "we need to fix different
/// densities ... make sure people can create their own custom densities"): opens the ``DensityLabWindowController``
/// over the active window, raised when it is already open. It sets the Sidebar Row Tuner's numbers per density, so it
/// binds here beside that tuner.
@MainActor
public struct DensityLabAction {
    /// The catalog action.
    public static let id: ActionID = "debug.densityLab"

    private let settings: @MainActor () -> SettingsController?
    private let sidebar: @MainActor () -> SidebarView?

    /// - Parameters:
    ///   - settings: The settings controller custom densities are written through.
    ///   - sidebar: The active window's sidebar; its window is the one the lab captures.
    public init(settings: @escaping @MainActor () -> SettingsController?, sidebar: @escaping @MainActor () -> SidebarView?) {
        self.settings = settings
        self.sidebar = sidebar
    }

    /// Binds the action.
    public func bind(into registry: ActionRegistry) {
        let sidebar = sidebar
        let lab = DensityLabWindowController(hooks: DensityLabHooks(
            targetWindow: { sidebar()?.window ?? NSApp.mainWindow },
            sidebarTunables: SidebarRowTuning.computed, settings: settings))
        registry.bindEffect(Self.id, effect: { _ in
            lab.show()
            return .done
        })
    }
}
