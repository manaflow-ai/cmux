import CMUXMobileCore
import Foundation

/// One paywall session: where it was opened and the configuration it shows.
///
/// The paywall fixes its context when it first appears, so the variant in its
/// events cannot change while it is on screen, even if a refresh brings a
/// different configuration.
public struct BillingPaywallContext: Sendable, Equatable, Hashable {
    /// Where the paywall was opened.
    public let entryPoint: BillingEntryPoint
    /// The configuration shown.
    public let config: BillingPaywallConfig
    /// Whether the configuration came from the server.
    public let configSource: BillingPaywallConfigSource

    /// Creates a context.
    public init(entryPoint: BillingEntryPoint, config: BillingPaywallConfig, configSource: BillingPaywallConfigSource) {
        self.entryPoint = entryPoint
        self.config = config
        self.configSource = configSource
    }

    /// The experiment properties every paywall funnel event carries:
    /// `paywall_experiment`, `paywall_variant`, `entry_point`, plus
    /// `paywall_layout` and `paywall_config_source` (`server` or `built_in`).
    public var analyticsProperties: [String: AnalyticsValue] {
        [
            "entry_point": .string(entryPoint.rawValue),
            "paywall_experiment": .string(config.experiment),
            "paywall_variant": .string(config.variant),
            "paywall_layout": .string(config.layout.rawValue),
            "paywall_config_source": .string(configSource.rawValue),
        ]
    }
}
