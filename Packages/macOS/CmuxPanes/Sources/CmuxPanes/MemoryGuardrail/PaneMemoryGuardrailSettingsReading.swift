import Foundation

/// Read-only seam over the two guardrail settings the service consults each
/// tick: whether the guardrail is enabled, and the user's raw threshold in GB
/// (clamped and converted to bytes inside the service). Kept as a seam so the
/// panes package does not depend on the settings catalog; the app conformer
/// reads the live `SettingCatalog` values.
@MainActor
public protocol PaneMemoryGuardrailSettingsReading {
    /// `true` when the per-pane runaway-memory guardrail is turned on.
    var isEnabled: Bool { get }
    /// The user's configured threshold in gigabytes, before clamping.
    var rawThresholdGB: Double { get }
}
