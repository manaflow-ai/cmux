import CmuxPanes
import CmuxSettings
import Foundation

/// App-side conformer for the panes package's `PaneMemoryGuardrailSettingsReading`
/// seam, reading the live `SettingCatalog` runaway-memory-guardrail keys from
/// standard defaults. Kept here so the panes package does not depend on the
/// settings catalog.
@MainActor
struct PaneMemoryGuardrailSettings: PaneMemoryGuardrailSettingsReading {
    private static let enabledSetting = SettingCatalog().terminal.runawayMemoryGuardrailEnabled
    private static let thresholdGBSetting = SettingCatalog().terminal.runawayMemoryGuardrailThresholdGB

    var isEnabled: Bool {
        Self.enabledSetting.value(in: .standard)
    }

    var rawThresholdGB: Double {
        Self.thresholdGBSetting.value(in: .standard)
    }
}
