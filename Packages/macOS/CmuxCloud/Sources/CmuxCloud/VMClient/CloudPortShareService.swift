import Foundation

/// Errors returned while preparing an authenticated Cloud port publication.
public enum CloudPortShareError: Error, Equatable, Sendable {
    case publicPublication(hostname: String)
    case provisioning(state: String)
}

/// Creates or reuses a protected publication and only returns an active URL target.
public enum CloudPortShareService {
    /// Prepares the protected publication for one VM port.
    public static func prepare(
        client: VMClient,
        vmID: String,
        port: Int
    ) async throws -> VMPublication {
        let matches = try await client.listPublications(vmID: vmID, port: port)
        let protected = matches.first { $0.accessMode == .personal || $0.accessMode == .team }
        if let publicPublication = matches.first(where: { $0.accessMode == .public }), protected == nil {
            throw CloudPortShareError.publicPublication(hostname: publicPublication.hostname)
        }
        var publication = try await protected ?? client.createPublication(
            vmID: vmID,
            port: port,
            hostname: nil,
            accessMode: nil,
            teamID: nil
        )
        if publication.state != "active" {
            publication = try await client.verifyPublication(id: publication.id)
        }
        guard publication.state == "active" else {
            throw CloudPortShareError.provisioning(state: publication.state)
        }
        return publication
    }
}
