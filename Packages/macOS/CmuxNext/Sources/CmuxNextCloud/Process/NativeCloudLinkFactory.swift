import CryptoKit
package import Foundation

/// Production assembly of the original team's enrollment and the bundle-verified child.
package struct NativeCloudLinkFactory: Sendable {
    let identity: MacInstallIdentity
    let paths: CloudPaths
    let bundle: URL
    let home: URL
    let session: @Sendable () async throws -> String
    let name: String

    package init(identity: MacInstallIdentity, paths: CloudPaths, bundle: URL, home: URL,
                 session: @escaping @Sendable () async throws -> String, name: String) {
        self.identity = identity; self.paths = paths; self.bundle = bundle; self.home = home; self.session = session; self.name = name
    }
    package func make(_ scope: CloudTeamScope.Snapshot) async throws -> NativeCloudLinkLease {
        try await scope.recheck()
        let context = try await scope.nativeContext()
        let target = try await identity.nativeNetworkTarget(team: scope.team, context: context)
        try await scope.recheck()
        let label = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._ -".contains($0)) ? $0 : "-" }.prefix(63))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._ -"))
        let enrollment = try NativeDeviceEnrollment(scope: target.scope, identity: identity, paths: paths,
            native: NativeDeviceHTTPTransport(origin: target.origin), session: session, name: label.isEmpty ? "cmux" : label,
            context: scope.nativeContext, recheck: scope.recheck)
        let namespace = try JSONEncoder().encode([scope.account, scope.team, target.scope.tenant, target.scope.mesh, target.origin.absoluteString])
        let key = SHA256.hash(data: namespace).map { String(format: "%02x", $0) }.joined()
        let child = NativeCloudLinkChild(bundleURL: bundle, publisher: try .current(),
            directory: paths.root.appendingPathComponent("native-links/\(key)/link"), home: home, prepare: {
                try await scope.recheck()
                let startup = try await enrollment.linkStartup()
                try await scope.recheck()
                return NativeCloudLinkStartup(bytes: startup.bytes, publicKey: startup.publicKey, recheck: {
                    try await scope.recheck(); try await startup.recheck(); try await scope.recheck()
                })
            }, reply: { bytes in
                try await scope.recheck()
                let result = try await enrollment.cloudBrokerReply(bytes)
                try await scope.recheck()
                return result
            })
        return NativeCloudLinkLease(child: child, stop: { await enrollment.stop() }, revoke: { try await enrollment.revoke() })
    }
}
