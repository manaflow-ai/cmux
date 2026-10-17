import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// The providers of another team's machines that back an open surface.
    ///
    /// A provider that lost access is retained too: its panes keep their card,
    /// and only the owning team's own status read can confirm or clear the
    /// loss. The selected team's page never decides another team's machine.
    static func retainedForeignMachineIDs(
        _ providers: [String: CmuxTuiSurfaceProvider],
        projected: Set<SurfaceMachineID>,
        activeTeamID active: String?
    ) -> Set<String> {
        Set(providers.compactMap { id, provider in
            guard let owner = provider.ownerTeamID, owner != active,
                  projected.contains(.cloud(id)) else { return nil }
            return id
        })
    }

    /// The team whose status read decides another team's open machine; nil
    /// when the selected team's page covers it or nothing could change.
    /// A machine-scoped loss keeps its read, so an authorized answer can clear
    /// a loss that was wrong. A revoked sign-in waits for the next sign-in.
    static func foreignStatusReadTeam(of provider: CmuxTuiSurfaceProvider, activeTeamID active: String?) -> String? {
        guard let owner = provider.ownerTeamID, owner != active,
              provider.accessLoss?.isMachineScoped != false else { return nil }
        return owner
    }
}
