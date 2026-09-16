import Foundation

extension CmuxFeatureFlags {
    static let sidebarCloudButtonDefault = true

    // FLAG(key: sidebar-cloud-button-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-12-01, defaultWhenUnavailable: true)
    // Shows the Cloud button in the bottom-left sidebar footer (left of Help),
    // which opens the right sidebar's Cloud tab. The remote value is a release
    // kill switch; the Cloud Machines beta and the sidebar.showCloudButton
    // setting still gate the button on top of it.
    nonisolated static let sidebarCloudButtonFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-cloud-button-enabled-release",
        title: String(localized: "featureFlags.sidebarCloudButton.title", defaultValue: "Sidebar Cloud button"),
        flagDescription: String(
            localized: "featureFlags.sidebarCloudButton.description",
            defaultValue: "Shows the Cloud button in the sidebar footer that opens the Cloud tab."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.sidebarCloudButtonDefault
    )

    var isSidebarCloudButtonEnabled: Bool {
        effectiveValue(for: Self.sidebarCloudButtonFlag)
    }
}
