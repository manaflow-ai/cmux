import Foundation

struct DockConfigResolution: Sendable {
    let controls: [DockControlDefinition]
    let floats: [DockFloatingDockDefinition]
    let sourceURL: URL?
    let baseDirectory: String
    let isProjectSource: Bool
    /// Durable source component used by seed identities. Source-aware resolvers
    /// pass a transport-qualified canonical identifier for remote configs.
    let floatingDockSeedSourceIdentifier: String?

    init(
        controls: [DockControlDefinition],
        floats: [DockFloatingDockDefinition] = [],
        sourceURL: URL?,
        baseDirectory: String,
        isProjectSource: Bool,
        floatingDockSeedSourceIdentifier: String? = nil
    ) {
        self.controls = controls
        self.floats = floats
        self.sourceURL = sourceURL
        self.baseDirectory = baseDirectory
        self.isProjectSource = isProjectSource
        self.floatingDockSeedSourceIdentifier = floatingDockSeedSourceIdentifier
            ?? sourceURL?.standardizedFileURL.path
    }
}
