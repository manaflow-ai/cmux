import CmuxMobileWire

/// `read git.status`: the repository of a shared folder (branch, HEAD,
/// upstream, base, ahead and behind), read only.
public struct GitStatusReadHandler: MobileReadHandler {
    let files: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider
    let reader: any MobileGitReader

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        guard let params = try? frame.params.decode(as: GitStatusParams.self) else {
            throw MobileDaemonError.filesInvalid("bad git.status params")
        }
        let policy = MobileFilePolicy(configuration: files, roots: await roots.roots(for: principal))
        let (_, status) = try await GitScope.resolve(params.path, policy: policy, reader: reader)
        return try JSONValue(encoding: status)
    }
}
