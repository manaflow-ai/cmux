import Foundation

/// Where the user opened the plans screen or the paywall; sent as
/// `entry_point` on the paywall funnel events.
public enum BillingEntryPoint: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    /// Settings > Plan.
    case settings
    /// The Upgrade card at the top of Settings, for a Free account.
    case settingsUpgradeCard = "settings_upgrade_card"
    /// The upgrade banner where Cloud machines are listed, for a Free account.
    case cloudBanner = "cloud_banner"
    /// New Machine, tapped by a Free account that cannot create one.
    case cloudNewMachine = "cloud_new_machine"
    /// A locked machine size in the New Machine sheet.
    case lockedMachineSize = "locked_vm_size"
    /// The Cloud service refused an action with a plan limit (HTTP 402).
    case limit
    /// An upgrade action in the Cloud machine sheet. Builds before the
    /// paywall sent this for the locked machine size.
    case cloudUpgrade = "cloud_upgrade"
    /// The staff-only Paywall Lab preview.
    case paywallLab = "paywall_lab"

    public var id: String { rawValue }
}
