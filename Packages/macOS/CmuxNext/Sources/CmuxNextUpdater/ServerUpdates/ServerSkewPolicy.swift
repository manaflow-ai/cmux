import Foundation

/// Decides whether a server is older than this app in a way a restart fixes. Capabilities decide
/// what the notice names; a build that differs from the bundled one also gets a notice, with no
/// feature list: the restart is how the update reaches that server.
public nonisolated struct ServerSkewPolicy: Sendable {
    /// Names the features in a notice.
    public let catalog: ServerFeatureCatalog

    /// - Parameter catalog: The feature names (default: the shipped catalog).
    public init(catalog: ServerFeatureCatalog = .shipped) {
        self.catalog = catalog
    }

    /// The notice for `handshake`, or nil when a restart would gain nothing.
    /// - Parameters:
    ///   - handshake: What the server said.
    ///   - appCapabilities: The optional capabilities this app uses and its bundled server serves.
    ///   - bundledBuild: The bundled server's build; nil when unknown or not comparable (a remote host).
    public func notice(for handshake: ServerHandshake, appCapabilities: Set<String>,
                       bundledBuild: String?) -> ServerUpdateNotice? {
        let impact = ServerRestartImpact(kind: handshake.kind, keepsWork: handshake.keepsWorkAcrossRestart)
        guard let served = handshake.capabilities else {
            guard let running = handshake.build, let bundledBuild, running != bundledBuild else { return nil }
            return ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: running,
                                      missingCapabilities: [], gainedFeatures: [], impact: impact)
        }
        let missing = appCapabilities.subtracting(served)
        guard !missing.isEmpty else {
            guard let running = handshake.build, let bundledBuild, running != bundledBuild else { return nil }
            return ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: running,
                                      missingCapabilities: [], gainedFeatures: [], impact: impact)
        }
        return ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: handshake.build,
                                  missingCapabilities: missing.sorted(), gainedFeatures: catalog.features(for: missing),
                                  impact: impact)
    }
}
