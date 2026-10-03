import Foundation

/// Errors returned while preparing an authenticated Cloud port publication.
public enum CloudPortShareError: Error, Equatable, Sendable {
    case publicPublication(hostname: String)
    case provisioning(state: String)
}

/// Creates or reuses a protected publication and only returns an active URL target.
public struct CloudPortShareService {
    public init() {}
    /// Prepares the protected publication for one VM port.
    public func prepare(
        client: VMClient,
        vmID: String,
        port: Int
    ) async throws -> VMPublication {
        let matches = try await client.listPublications(vmID: vmID, port: port)
        // A share copied from the Cloud tree is intended for the current team,
        // so teammates with the same account access can open it after signing in.
        // Passing nil for both fields relied on a backend default that is not
        // stable across account and team scopes, and could leave the publication
        // unavailable even though the request appeared to succeed.
        let resolvedTeamID = await client.auth.resolvedTeamID
        let selectedTeamID = resolvedTeamID.flatMap { teamID in
            let trimmed = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let requestedAccessMode: VMPublicationAccessMode = selectedTeamID == nil ? .personal : .team
        let protected = matches.first {
            guard $0.accessMode == requestedAccessMode else { return false }
            if requestedAccessMode == .team {
                return $0.teamID == selectedTeamID
            }
            return $0.teamID == nil
        }
        if let publicPublication = matches.first(where: { $0.accessMode == .public }), protected == nil {
            throw CloudPortShareError.publicPublication(hostname: publicPublication.hostname)
        }
        var publication: VMPublication
        if let protected {
            publication = protected
        } else {
            publication = try await client.createPublication(
                vmID: vmID,
                port: port,
                hostname: nil,
                accessMode: requestedAccessMode,
                teamID: selectedTeamID
            )
        }
        if publication.state != "active" {
            publication = try await client.verifyPublication(id: publication.id)
        }
        guard publication.state == "active" else {
            throw CloudPortShareError.provisioning(state: publication.state)
        }
        return publication
    }
}
