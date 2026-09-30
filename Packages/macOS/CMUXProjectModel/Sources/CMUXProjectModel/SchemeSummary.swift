import Foundation

/// One Xcode scheme parsed from `xcshareddata/xcschemes/*.xcscheme` or the
/// per-user `xcuserdata/.../xcschemes/*.xcscheme`.
///
/// The shared-vs-personal distinction is collapsed to ``isShared`` rather
/// than exposed as a path so the UI can render a single badge instead of
/// leaking on-disk file locations.
public struct SchemeSummary: Sendable, Hashable, Identifiable {
    public let id: SchemeID
    public let name: String
    public let isShared: Bool
    public let runTargetIDs: [TargetID]
    public let testTargetIDs: [TargetID]
    public let profileTargetID: TargetID?
    public let archiveTargetID: TargetID?
    public let launchArguments: [String]
    public let environmentVariables: [String: String]

    public init(
        id: SchemeID,
        name: String,
        isShared: Bool,
        runTargetIDs: [TargetID],
        testTargetIDs: [TargetID],
        profileTargetID: TargetID?,
        archiveTargetID: TargetID?,
        launchArguments: [String],
        environmentVariables: [String: String]
    ) {
        self.id = id
        self.name = name
        self.isShared = isShared
        self.runTargetIDs = runTargetIDs
        self.testTargetIDs = testTargetIDs
        self.profileTargetID = profileTargetID
        self.archiveTargetID = archiveTargetID
        self.launchArguments = launchArguments
        self.environmentVariables = environmentVariables
    }
}
