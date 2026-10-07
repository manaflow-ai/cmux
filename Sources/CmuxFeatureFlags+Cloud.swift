import Foundation

extension CmuxFeatureFlags {
    // FLAG(key: cloud-machines-enabled-release, owner: austinwang,
    //      reviewBy: 2026-11-01, defaultWhenUnavailable: cloudMachinesDefault)
    // Remote kill switch for the macOS Cloud integration. Cloud is available to
    // everyone; the fallback keeps the Cloud tab visible when the flag service
    // is unreachable. Users still enable Cloud Machines from that tab.
    nonisolated static let cloudMachinesFlag = CmuxFeatureFlagDefinition(
        key: "cloud-machines-enabled-release",
        title: String(localized: "featureFlags.cloudMachines.title", defaultValue: "Cloud Machines"),
        flagDescription: String(
            localized: "featureFlags.cloudMachines.description",
            defaultValue: "Enables the macOS Cloud Machines integration, including entry points, attachments, and background sync."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.cloudMachinesDefault
    )

    var isCloudMachinesEnabled: Bool { effectiveValue(for: Self.cloudMachinesFlag) }
}
