import Foundation

/// Which in-app surface opened the upgrade flow. The raw value travels to the
/// web as `cmux_source`, is stored on the Stripe Checkout Session, and comes
/// back on every PostHog billing event, so a paid subscription can be traced to
/// the button that started it. Raw values are lowercase `[a-z0-9_]` tokens;
/// the server drops anything else.
public enum ProUpgradeSource: String, CaseIterable, Sendable {
    /// "Upgrade" capsule in the sidebar footer.
    case sidebarBadge = "mac_sidebar_badge"
    /// "Upgrade to cmux Pro…" in the sidebar footer account menu.
    case sidebarAccountMenu = "mac_sidebar_account_menu"
    /// "Upgrade to cmux Pro…" in the sidebar help (?) menu.
    case sidebarHelpMenu = "mac_sidebar_help_menu"
    /// Help > "Upgrade to cmux Pro…" in the main menu bar.
    case helpMenu = "mac_help_menu"
    /// Command palette "Upgrade to cmux Pro".
    case commandPalette = "mac_command_palette"
    /// Settings > Account card "Upgrade" (via `AccountFlow`).
    case settingsAccountCard = "mac_settings_account_card"
    /// Settings > Cloud machines billing.
    case settingsCloudMachines = "mac_settings_cloud_machines"
    /// Machines panel empty state: plan does not include Cloud machines.
    case machinesPanelRequiresPro = "mac_machines_panel_requires_pro"
    /// Machines panel nudge under the create button.
    case machinesPanelUpgradeNudge = "mac_machines_panel_upgrade_nudge"
    /// Machines panel free-access countdown / expired banner.
    case machinesPanelTrialBanner = "mac_machines_panel_trial_banner"
    /// Machines panel row action that needs a paid plan.
    case machinesPanelMachineAction = "mac_machines_panel_machine_action"
    /// New machine sheet refused because the free plan is at its limit.
    case newMachineAtLimit = "mac_new_machine_at_limit"
    /// New machine sheet "Upgrade to Max" under the locked 32 GB / 64 GB sizes.
    case newMachineSheetMaxUpgrade = "mac_new_machine_sheet_max_upgrade"
    /// Link inside the `vm_memory_requires_plan` error text (`VMClient`).
    case vmMemoryRequiresPlanError = "mac_vm_memory_requires_plan_error"
    /// DEBUG native pricing window.
    case nativePricingPreview = "mac_native_pricing_preview"
    /// Link inside the `vm_requires_pro` error text (`VMClient`); the token
    /// is spelled out in the localized string, so the test pins it here.
    case vmRequiresProError = "mac_vm_requires_pro_error"
}
