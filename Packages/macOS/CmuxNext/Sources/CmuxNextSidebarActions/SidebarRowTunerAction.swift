import AppKit
public import CmuxNextActions
import CmuxNextSettingsWindow
import CmuxNextSidebar

/// Command Palette "Debug: Sidebar Row Tuner" (`debug.sidebarRowTuner`, DEV and NIGHTLY; Lawrence 2026-11-12: "we need
/// to build a ui to fix the ui so i can hand tune the values"): opens a ``TuningPanelWindow`` over
/// ``SidebarRowTuning``, one panel per registry, raised when it is already open. Debug Settings > Sidebar Rows lists the
/// same values.
@MainActor
public struct SidebarRowTunerAction {
    /// The catalog action.
    public static let id: ActionID = "debug.sidebarRowTuner"

    /// The action, with nothing to inject: the panel edits the shared tunable store the sidebar reads.
    public init() {}

    /// Binds the action.
    public func bind(into registry: ActionRegistry) {
        let tuner = TuningPanelWindow(
            title: TuningPanelStrings.sidebarRows, descriptors: SidebarRowTuning.all,
            export: TuningPanelExport(choiceType: { $0.key.hasSuffix("Weight") ? "NSFont.Weight" : nil }),
            activeLook: nil)
        registry.bindEffect(Self.id, effect: { _ in
            tuner.show()
            return .done
        })
    }
}
