import Foundation

@MainActor
extension FileExplorerStore {
    func applyRemoteSSHWorkspaceRoot(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath requestedRootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        sshTransport: SSHFileExplorerTransport
    ) {
        setWorkspaceRootIdentity(workspaceId)

        let existingProvider = provider as? SSHFileExplorerProvider
        let sshProvider: SSHFileExplorerProvider
        if let existingProvider,
           existingProvider.connection == connection,
           existingProvider.displayTarget == displayTarget {
            sshProvider = existingProvider
            sshProvider.updateAvailability(isAvailable, homePath: nil)
        } else {
            cancelRemoteHomeResolution()
            setRootPath("")
            sshProvider = SSHFileExplorerProvider(
                connection: connection,
                displayTarget: displayTarget,
                homePath: "",
                isAvailable: isAvailable,
                transport: sshTransport
            )
            setProvider(sshProvider, reloadIfAvailable: false)
        }

        guard isAvailable else {
            cancelRemoteHomeResolution()
            setRootPath("")
            let detail = unavailableDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                setRootStatusMessage(
                    String(
                        format: String(localized: "fileExplorer.status.sshUnavailableWithDetail", defaultValue: "SSH files unavailable: %@"),
                        detail
                    )
                )
            } else {
                setRootStatusMessage(
                    String(localized: "fileExplorer.status.sshUnavailable", defaultValue: "SSH files unavailable")
                )
            }
            return
        }

        let requestedRootPath = Self.normalizedRootPath(requestedRootPath)
        let currentHomePath = sshProvider.homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedRootPath {
            if requestedRootPath == "~" || requestedRootPath.hasPrefix("~/") {
                guard !currentHomePath.isEmpty else {
                    resolveRemoteHome(
                        workspaceId: workspaceId,
                        provider: sshProvider,
                        providerKey: Self.remoteProviderKey(connection: connection),
                        requestedRootPath: requestedRootPath
                    )
                    return
                }
                cancelRemoteHomeResolution()
                setRootStatusMessage(nil)
                setRootPath(Self.expandTilde(requestedRootPath, home: currentHomePath))
                return
            }
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            setRootPath(requestedRootPath)
            return
        }

        if !currentHomePath.isEmpty {
            setRootStatusMessage(nil)
            setRootPath(currentHomePath)
            return
        }

        resolveRemoteHome(
            workspaceId: workspaceId,
            provider: sshProvider,
            providerKey: Self.remoteProviderKey(connection: connection)
        )
    }

    func applyRemoteCloudWorkspaceRoot(
        workspaceId: UUID,
        vmID: String,
        displayTarget: String,
        rootPath requestedRootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        target: CloudFileExplorerTarget?
    ) {
        setWorkspaceRootIdentity(workspaceId)

        let existingProvider = provider as? CloudVMFileExplorerProvider
        let cloudProvider: CloudVMFileExplorerProvider
        if let existingProvider,
           existingProvider.vmID == vmID,
           existingProvider.target == target,
           existingProvider.displayTarget == displayTarget,
           existingProvider.isAvailable == isAvailable {
            cloudProvider = existingProvider
        } else {
            cancelRemoteHomeResolution()
            setRootPath("")
            cloudProvider = CloudVMFileExplorerProvider(
                vmID: vmID,
                displayTarget: displayTarget,
                isAvailable: isAvailable, target: target
            )
            setProvider(cloudProvider, reloadIfAvailable: false)
        }

        guard isAvailable else {
            cancelRemoteHomeResolution()
            setRootPath("")
            let detail = unavailableDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            setRootStatusMessage(
                detail?.isEmpty == false
                    ? String(
                        format: String(localized: "fileExplorer.status.remoteUnavailableWithDetail", defaultValue: "Remote files unavailable: %@"),
                        detail!
                    )
                    : String(localized: "fileExplorer.status.remoteUnavailable", defaultValue: "Remote files unavailable")
            )
            return
        }

        if let requestedRootPath = Self.normalizedRootPath(requestedRootPath) {
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            setRootPath(requestedRootPath)
            return
        }

        let currentHomePath = cloudProvider.homePath
        if !currentHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setRootStatusMessage(nil)
            setRootPath(currentHomePath)
            return
        }

        resolveRemoteHome(workspaceId: workspaceId, provider: cloudProvider, providerKey: vmID)
    }

    func resolveRemoteHome(
        workspaceId: UUID,
        provider: any RemoteFileExplorerProvider,
        providerKey: String,
        requestedRootPath: String? = nil
    ) {
        let resolutionKey = [
            workspaceId.uuidString,
            providerKey,
            requestedRootPath ?? "",
        ].joined(separator: "\u{1e}")

        guard remoteHomeResolutionKey != resolutionKey else { return }
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionKey = resolutionKey
        setRootPath("")
        setRootStatusMessage(String(localized: "fileExplorer.status.remoteResolvingHome", defaultValue: "Resolving remote home..."))

        remoteHomeResolutionTask = Task { [weak self, weak provider] in
            guard let provider else { return }
            do {
                let homePath = try await provider.resolveHomePath()
                await MainActor.run { [weak self, weak provider] in
                    guard let self,
                          let provider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === provider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    if let sshProvider = provider as? SSHFileExplorerProvider {
                        sshProvider.updateAvailability(true, homePath: homePath)
                    } else if let cloudProvider = provider as? CloudVMFileExplorerProvider {
                        self.setProvider(cloudProvider.resolvingHome(homePath), reloadIfAvailable: false)
                    }
                    self.setRootStatusMessage(nil)
                    let resolvedRoot = requestedRootPath.flatMap { rootPath in
                        rootPath == "~" || rootPath.hasPrefix("~/")
                            ? Self.expandTilde(rootPath, home: homePath)
                            : rootPath
                    } ?? homePath
                    self.setRootPath(resolvedRoot)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, weak provider] in
                    guard let self,
                          let provider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === provider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    self.setRootPath("")
                    self.setRootStatusMessage(
                        String(
                            format: String(localized: "fileExplorer.status.remoteHomeFailed", defaultValue: "Unable to resolve remote home: %@"),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    func cancelRemoteHomeResolution() {
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionTask = nil
        remoteHomeResolutionKey = nil
    }

    static func path(_ candidate: String, isContainedIn root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func normalizedRootPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        let normalizedHome = home.hasSuffix("/") && home != "/"
            ? String(home.dropLast())
            : home
        if path == "~" { return normalizedHome }
        guard path.hasPrefix("~/") else { return path }
        return normalizedHome + "/" + path.dropFirst(2)
    }

    private static func remoteProviderKey(connection: SSHFileExplorerConnection) -> String {
        connection.identityComponents.joined(separator: "\u{1e}")
    }

}
