import Foundation

/// A buildable target inside a ``ProjectModule``.
///
/// The summary fields are everything the Targets tab and the navigator's
/// membership chips need without paying the cost of running
/// `xcodebuild -showBuildSettings`. Resolved settings are populated lazily
/// when the user opens the Build Settings tab.
public struct TargetSummary: Sendable, Hashable, Identifiable {
    public let id: TargetID
    public let displayName: String
    public let productType: TargetProductType
    public let platforms: [String]
    public let bundleIdentifier: String?
    public let deploymentTarget: String?
    public let dependencies: [TargetID]

    public init(
        id: TargetID,
        displayName: String,
        productType: TargetProductType,
        platforms: [String],
        bundleIdentifier: String?,
        deploymentTarget: String?,
        dependencies: [TargetID]
    ) {
        self.id = id
        self.displayName = displayName
        self.productType = productType
        self.platforms = platforms
        self.bundleIdentifier = bundleIdentifier
        self.deploymentTarget = deploymentTarget
        self.dependencies = dependencies
    }
}
