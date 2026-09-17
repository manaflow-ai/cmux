import Foundation

extension CmuxFeatureFlags {
    // FLAG(key: cloud-machines-enabled-release, owner: austinwang,
    //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
    // Release keeps the remote kill switch and defaults off. Recognized DEBUG
    // bundles force the flag on so every tagged development build dogfoods the
    // same Cloud surface regardless of the remote rollout value.
#if DEBUG
    fileprivate static let cloudMachinesDefault = true
#else
    fileprivate static let cloudMachinesDefault = false
#endif

    nonisolated static let cloudMachinesFlag = CmuxFeatureFlagDefinition(
        key: "cloud-machines-enabled-release",
        title: String(localized: "featureFlags.cloudMachines.title", defaultValue: "Cloud Machines"),
        flagDescription: String(
            localized: "featureFlags.cloudMachines.description",
            defaultValue: "Enables the macOS Cloud Machines integration, including entry points, attachments, and background sync."
        ),
        defaultWhenUnavailable: cloudMachinesDefault
    )

    var isCloudMachinesEnabled: Bool { effectiveValue(for: Self.cloudMachinesFlag) }
}
