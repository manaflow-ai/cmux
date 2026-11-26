/// Chooses the Mac installations that may appear in a surface directory.
/// Authenticated discovery defines membership; presence and saved rows only
/// contribute membership when the caller explicitly uses legacy pairing.
public struct SurfaceDeviceDirectoryAdmission: Sendable {
    private let requiresAuthenticatedDiscovery: Bool

    /// Creates the membership policy for this directory owner.
    /// - Parameter requiresAuthenticatedDiscovery: Whether current authenticated hosts are required.
    public init(requiresAuthenticatedDiscovery: Bool) {
        self.requiresAuthenticatedDiscovery = requiresAuthenticatedDiscovery
    }

    /// Computes membership after source identities have been joined.
    /// - Parameters:
    ///   - authenticated: Installations named by the authenticated Mac host directory.
    ///   - legacySources: Registry, presence, saved pairing, and retained row identities.
    ///   - local: This Mac's installation, whose physical device must remain hidden.
    /// - Returns: The permitted remote installation identities.
    public func admittedInstances(
        authenticated: Set<SurfaceDeviceInstanceID>,
        legacySources: [Set<SurfaceDeviceInstanceID>],
        local: SurfaceDeviceInstanceID
    ) -> Set<SurfaceDeviceInstanceID> {
        var result = authenticated
        if !requiresAuthenticatedDiscovery {
            for source in legacySources { result.formUnion(source) }
        }
        return result.filter { $0.isVisible(from: local) }
    }
}
