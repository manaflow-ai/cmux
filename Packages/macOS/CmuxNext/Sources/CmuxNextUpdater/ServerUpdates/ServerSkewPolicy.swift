import Foundation

/// Decides whether a server is older than this app in a way a restart fixes. Capabilities decide;
/// a build difference matters only for a server that advertises none.
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
    ///   - bundledBuild: The bundled server's build, compared only when the server advertises no
    ///     capabilities.
    public func notice(for handshake: ServerHandshake, appCapabilities: Set<String>,
                       bundledBuild: String?) -> ServerUpdateNotice? {
        let impact = ServerRestartImpact(kind: handshake.kind, keepsWork: handshake.keepsWorkAcrossRestart)
        guard let served = handshake.capabilities else {
            guard let running = handshake.build, let bundledBuild, running != bundledBuild else { return nil }
            return ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: running,
                                      missingCapabilities: [], gainedFeatures: [], impact: impact)
        }
        let missing = appCapabilities.subtracting(served)
        guard !missing.isEmpty else { return nil }
        return ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: handshake.build,
                                  missingCapabilities: missing.sorted(), gainedFeatures: catalog.features(for: missing),
                                  impact: impact)
    }
}
