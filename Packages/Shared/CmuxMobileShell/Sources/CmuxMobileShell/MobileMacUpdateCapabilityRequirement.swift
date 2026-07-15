/// A Mac host capability and the mobile-visible feature it enables.
public struct MobileMacUpdateCapabilityRequirement: Sendable, Equatable {
    /// The stable capability identifier advertised by a Mac host.
    public let capability: String

    /// The mobile-visible feature enabled by the capability.
    public let feature: MobileMacUpdateFeature

    /// The first released Mac marketing version that advertises the capability.
    ///
    /// A `nil` value means the capability has not shipped in a Mac release, so the
    /// update advisor never claims that updating unlocks it.
    public let firstReleasedMacVersion: MobileMacAppVersion?

    /// Creates a capability requirement for the update advisor.
    ///
    /// - Parameters:
    ///   - capability: The stable capability identifier advertised by a Mac host.
    ///   - feature: The mobile-visible feature enabled by the capability.
    ///   - firstReleasedMacVersion: The first released Mac version containing the capability, or `nil` if unreleased.
    public init(
        capability: String,
        feature: MobileMacUpdateFeature,
        firstReleasedMacVersion: MobileMacAppVersion?
    ) {
        self.capability = capability
        self.feature = feature
        self.firstReleasedMacVersion = firstReleasedMacVersion
    }

    /// The capability release registry known to this iOS build.
    ///
    /// Update an unreleased entry when its capability first ships in a Mac release.
    // lint:allow singleton — `standard` is the spec-required immutable declaration registry, not runtime state.
    public static let standard: [MobileMacUpdateCapabilityRequirement] = [
        .init(
            capability: "workspace.actions.v1",
            feature: .workspaceActions,
            firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.15")
        ),
        .init(
            capability: "workspace.read_state.v1",
            feature: .workspaceReadState,
            firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.16")
        ),
        .init(
            capability: "workspace.close.v1",
            feature: .workspaceClose,
            firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.16")
        ),
        .init(
            capability: "workspace.groups.v1",
            feature: .workspaceGroups,
            firstReleasedMacVersion: MobileMacAppVersion(parsing: "0.64.16")
        ),
        .init(capability: "workspace.move.v1", feature: .workspaceMove, firstReleasedMacVersion: nil),
        .init(capability: "workspace.group_actions.v1", feature: .workspaceGroupActions, firstReleasedMacVersion: nil),
        .init(capability: "workspace.create_in_group.v1", feature: .workspaceCreateInGroup, firstReleasedMacVersion: nil),
        .init(capability: "workspace.group_create.v1", feature: .workspaceGroupCreate, firstReleasedMacVersion: nil),
    ]
}
