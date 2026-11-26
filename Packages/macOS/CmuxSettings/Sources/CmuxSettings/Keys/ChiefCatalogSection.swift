import Foundation

/// The agent harness Chief runs its conversations on (`chief.harness`).
public enum ChiefHarnessSetting: String, CaseIterable, Sendable {
    /// Claude Code, the default harness.
    case claude
    /// OpenAI Codex.
    case codex

    /// The harness used when `chief.harness` is unset or invalid.
    public static let defaultHarness: ChiefHarnessSetting = .claude
}

/// Settings under the dotted-id prefix `chief.*`.
///
/// Chief is the Home agent. ``enabled`` hides the Home row and every Chief
/// entry point when off; ``harness``, ``model`` and ``effort`` pick the agent
/// that answers. An empty ``model`` or ``effort`` means the harness default.
/// ``dangerouslySkipPermissions`` is an explicit opt-in for bypassing agent
/// permission prompts and is off by default.
public struct ChiefCatalogSection: SettingCatalogSection {
    /// Whether the Home row and Chief entry points are shown.
    public let enabled = DefaultsKey<Bool>(
        id: "chief.enabled",
        defaultValue: true,
        userDefaultsKey: "chiefEnabled"
    )

    /// The harness raw value, one of ``ChiefHarnessSetting`` (`"claude"` or `"codex"`).
    public let harness = DefaultsKey<String>(
        id: "chief.harness",
        defaultValue: "claude",
        userDefaultsKey: "chiefHarness"
    )

    /// The model passed to the harness; empty means the harness default.
    public let model = DefaultsKey<String>(
        id: "chief.model",
        defaultValue: "",
        userDefaultsKey: "chiefModel"
    )

    /// The reasoning effort passed to the harness; empty means the harness default.
    public let effort = DefaultsKey<String>(
        id: "chief.effort",
        defaultValue: "",
        userDefaultsKey: "chiefEffort"
    )

    /// Whether Chief may bypass agent permission prompts. Off by default.
    public let dangerouslySkipPermissions = DefaultsKey<Bool>(
        id: "chief.dangerouslySkipPermissions",
        defaultValue: false,
        userDefaultsKey: "chiefDangerouslySkipPermissions"
    )

    /// Creates the Chief settings section with its default keys.
    public init() {}
}
