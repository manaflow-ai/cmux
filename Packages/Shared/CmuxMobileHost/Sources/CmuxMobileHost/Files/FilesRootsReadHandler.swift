import CmuxMobileWire

/// `read files.roots`: the directories this device may reach, inbox first.
public struct FilesRootsReadHandler: MobileReadHandler {
    let configuration: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider

    init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider) {
        self.configuration = configuration
        self.roots = roots
    }

    public func read(_ frame: ReadFrame, principal: MobileDevicePrincipal) async throws -> JSONValue {
        let policy = MobileFilePolicy(configuration: configuration, roots: await roots.roots(for: principal))
        let result = FilesRootsResult(roots: policy.roots.map {
            FilesRoot(id: $0.root.id, name: $0.root.name, path: $0.path, writable: $0.root.writable)
        })
        return try JSONValue(encoding: result)
    }
}
