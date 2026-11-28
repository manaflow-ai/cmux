import Foundation

/// One named build configuration ("Debug", "Release", custom names) attached
/// to either a project or a target.
///
/// ``rawSettings`` is the literal `buildSettings` dictionary from the
/// underlying `XCBuildConfiguration` object. Keys may carry conditional
/// suffixes such as `OTHER_LDFLAGS[sdk=iphoneos*][config=Debug]`; the
/// Build Settings view is responsible for parsing those suffixes when it
/// computes the Levels rows.
public struct BuildConfigSummary: Sendable, Hashable, Identifiable {
    public let id: BuildConfigID
    public let name: String
    public let scope: BuildConfigScope
    public let baseConfigurationPath: URL?
    public let rawSettings: [String: String]

    public init(
        id: BuildConfigID,
        name: String,
        scope: BuildConfigScope,
        baseConfigurationPath: URL?,
        rawSettings: [String: String]
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.baseConfigurationPath = baseConfigurationPath
        self.rawSettings = rawSettings
    }
}
