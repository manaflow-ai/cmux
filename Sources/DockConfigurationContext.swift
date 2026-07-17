import Foundation

struct DockConfigurationContext: Sendable {
    struct Identity: Hashable, Sendable {
        let projectOrigin: DockConfigOrigin?
        let rootDirectory: String?
        let availabilityRevision: String
        let executionWorkspaceID: UUID?
        let includesGlobalFallback: Bool

        /// Whether both contexts address the same durable configuration and
        /// execution source. Availability revisions only request a fresh probe;
        /// they do not invalidate already-running panels from that source.
        func hasSameConfigurationSource(as other: Self) -> Bool {
            projectOrigin == other.projectOrigin &&
                rootDirectory == other.rootDirectory &&
                executionWorkspaceID == other.executionWorkspaceID &&
                includesGlobalFallback == other.includesGlobalFallback
        }
    }

    let identity: Identity
    let projectSource: DockProjectConfigSource?
    let includesGlobalFallback: Bool
    let emptyBaseDirectory: String

    static func legacy(scope: DockScope, rootDirectory: String?) -> DockConfigurationContext {
        let home = DockConfigPath(FileManager.default.homeDirectoryForCurrentUser.path)!
        let normalizedRoot = rootDirectory.flatMap(DockConfigPath.init)
        let projectSource: DockProjectConfigSource?
        if scope == .workspace, let normalizedRoot {
            projectSource = DockProjectConfigSource(
                origin: .local,
                fileSystem: LocalDockConfigFileSystem(),
                rootDirectory: normalizedRoot,
                boundaryDirectory: home,
                executionContext: .local
            )
        } else {
            projectSource = nil
        }
        return DockConfigurationContext(
            identity: Identity(
                projectOrigin: projectSource?.origin,
                rootDirectory: projectSource?.rootDirectory.value,
                availabilityRevision: "local",
                executionWorkspaceID: nil,
                includesGlobalFallback: scope == .global
            ),
            projectSource: projectSource,
            includesGlobalFallback: scope == .global,
            emptyBaseDirectory: normalizedRoot?.value ?? home.value
        )
    }
}
