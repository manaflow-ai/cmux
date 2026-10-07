public import CmuxMobileHost
public import CmuxNextDaemon

/// `MobileFileRootsProvider` over the daemon's tree, read per request so a
/// closed workspace stops being reachable at once. Every admitted device of
/// this account sees the same workspaces.
public struct DaemonFileRoots: MobileFileRootsProvider {
    private let tree: @Sendable () async throws -> DaemonTree

    public init(tree: @escaping @Sendable () async throws -> DaemonTree) {
        self.tree = tree
    }

    public init(daemon: DaemonMobileDaemon) {
        self.init { try await daemon.currentTree() }
    }

    public func roots(for principal: MobileDevicePrincipal) async -> [MobileFileRoot] {
        guard let tree = try? await tree() else { return [] }
        return tree.mobileFileRoots
    }
}
