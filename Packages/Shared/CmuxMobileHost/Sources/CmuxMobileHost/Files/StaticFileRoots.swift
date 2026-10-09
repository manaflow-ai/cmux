/// A fixed root list (tests, DEV, or an app that has not wired workspaces).
public struct StaticFileRoots: MobileFileRootsProvider {
    public var roots: [MobileFileRoot]

    public init(_ roots: [MobileFileRoot] = []) {
        self.roots = roots
    }

    public func roots(for principal: MobileDevicePrincipal) async -> [MobileFileRoot] {
        roots
    }
}
