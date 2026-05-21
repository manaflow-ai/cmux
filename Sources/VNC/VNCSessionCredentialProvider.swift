import CMUXVNC
import Foundation

enum VNCSessionCredentialProvider {
    static var defaultMacfleetManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macfleet/hosts.json")
    }

    static func credentialOffMainActor(for session: MacfleetVNCSession) async -> VNCResolvedCredential? {
        await Task.detached(priority: .userInitiated) {
            Self.credential(for: session)
        }.value
    }

    static func credential(
        for session: MacfleetVNCSession,
        manifest: MacfleetManifest? = nil,
        manifestURL: URL? = nil
    ) -> VNCResolvedCredential? {
        if let credential = VNCCredentialResolver.resolve(
            session: session,
            keychainPassword: VNCKeychainCredentialProvider.password(for: session)
        ) {
            return credential
        }

        let resolvedManifestURL = manifestURL ?? defaultMacfleetManifestURL
        let resolvedManifest = manifest ?? (try? MacfleetManifest.load(from: resolvedManifestURL))
        guard let manifestSession = resolvedManifest?.expandedSessions().first(where: {
            $0.hasSameConnectionIdentity(as: session)
        }) else {
            return nil
        }

        return VNCCredentialResolver.resolve(
            session: manifestSession,
            keychainPassword: VNCKeychainCredentialProvider.password(for: manifestSession)
        )
    }
}
