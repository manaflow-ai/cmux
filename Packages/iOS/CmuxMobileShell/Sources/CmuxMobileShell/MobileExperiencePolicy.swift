/// Product-level capability policy for the mobile client.
public struct MobileExperiencePolicy: Equatable, Sendable {
    /// The profile that drives this policy.
    public let profile: MobileExperienceProfile

    /// Creates a policy for a product profile.
    public init(profile: MobileExperienceProfile = .full) {
        self.profile = profile
    }

    /// The complete development and dogfood policy.
    public static let full = Self(profile: .full)
    /// The focused first-release policy.
    public static let mvp = Self(profile: .mvp)

    /// Whether the phone-local browser is available.
    public var allowsLocalBrowser: Bool { profile == .full }
    /// Whether Mac browser panes can be streamed to the phone.
    public var allowsBrowserStream: Bool { profile == .full }
    /// Whether workspace diffs and change summaries are available.
    public var allowsWorkspaceChanges: Bool { profile == .full }
    /// Whether artifact browsing and previews are available.
    public var allowsArtifacts: Bool { profile == .full }
    /// Whether workspace grouping, moving, and advanced mutations are available.
    public var allowsAdvancedWorkspaceManagement: Bool { profile == .full }
    /// Whether advanced relay and transport settings are available.
    public var allowsAdvancedNetworking: Bool { profile == .full }
    /// Whether the user can switch the active team from mobile settings.
    public var allowsTeamSwitching: Bool { profile == .full }

    /// Applies the profile to an authenticated host capability snapshot.
    ///
    /// Core terminal, task, notification, connection, and workspace lifecycle
    /// capabilities are preserved in every profile.
    public func filteredHostCapabilities(_ capabilities: Set<String>) -> Set<String> {
        guard profile == .mvp else { return capabilities }
        return capabilities.subtracting(Self.mvpDisabledHostCapabilities)
    }

    private static let mvpDisabledHostCapabilities: Set<String> = [
        "browser.stream.v1",
        "browser.stream.viewport.v1",
        "browser.stream.dialog.v1",
        "workspace.changes.v1",
        "workspace.move.v1",
        "workspace.group_actions.v1",
        "workspace.create_in_group.v1",
        "workspace.group_create.v1",
        "workspace.groups.v1",
        "chat.artifact.v1",
        "chat.artifact.gallery.v1",
        "chat.artifact.folders.v1",
        "terminal.artifact.v1",
        "terminal.artifact.list.v1",
        "iroh.artifact_lane.v1",
        "dogfood.v1",
    ]
}
