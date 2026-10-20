import Foundation

/// One project inside a ``ProjectModel``.
///
/// For the Xcode adapter a module is one `.xcodeproj`. A ``ProjectModel``
/// based on a `.xcworkspace` may contain many modules; a model loaded
/// directly from a single `.xcodeproj` always contains exactly one.
public struct ProjectModule: Sendable, Hashable, Identifiable {
    public let id: ProjectModuleID
    public let displayName: String
    public let rootURL: URL
    public let rootGroup: ProjectGroup
    public let targets: [TargetSummary]
    public let configurations: [BuildConfigSummary]
    public let schemes: [SchemeSummary]

    public init(
        id: ProjectModuleID,
        displayName: String,
        rootURL: URL,
        rootGroup: ProjectGroup,
        targets: [TargetSummary],
        configurations: [BuildConfigSummary],
        schemes: [SchemeSummary]
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.rootGroup = rootGroup
        self.targets = targets
        self.configurations = configurations
        self.schemes = schemes
    }

    /// Look up a target by id within this module.
    ///
    /// Convenience used by the navigator detail strip to translate a
    /// ``TargetMembership/targetID`` back into a display name.
    public func target(for id: TargetID) -> TargetSummary? {
        targets.first(where: { $0.id == id })
    }

    /// All distinct build configuration names ("Debug", "Release", ...) that
    /// appear at either project or target scope.
    public var configurationNames: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for config in configurations where !seen.contains(config.name) {
            seen.insert(config.name)
            ordered.append(config.name)
        }
        return ordered
    }
}
