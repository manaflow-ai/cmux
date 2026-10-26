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
        let currentHomePath = sshProvider.homePath
        if let requestedRootPath,
           let rootPath = Self.remoteRootPath(requestedRootPath, homePath: currentHomePath) {
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            setRootPath(rootPath)
            return
        }

        if !currentHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setRootStatusMessage(nil)
            setRootPath(currentHomePath)
            return
        }

        resolveRemoteHome(
            workspaceId: workspaceId,
            provider: sshProvider,
            providerKey: [
                connection.destination,
                connection.port.map(String.init) ?? "",
                connection.identityFile ?? "",
                connection.sshOptions.joined(separator: "\u{1f}")
            ].joined(separator: "\u{1e}"),
            requestedRootPath: requestedRootPath
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
                    self.setRootPath(
                        requestedRootPath.flatMap { Self.remoteRootPath($0, homePath: homePath) } ?? homePath
                    )
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
        var normalizedRoot = root
        while normalizedRoot.count > 1, normalizedRoot.hasSuffix("/") {
            normalizedRoot.removeLast()
        }
        var normalizedCandidate = candidate
        while normalizedCandidate.count > 1, normalizedCandidate.hasSuffix("/") {
            normalizedCandidate.removeLast()
        }
        if normalizedRoot == "/" {
            return normalizedCandidate.hasPrefix("/")
        }
        return normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/")
    }

    private static func normalizedRootPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // A remote shell title reports its cwd as `~` or `~/...`, which the quoted
    // listing path cannot expand. nil until the remote home is known.
    private static func remoteRootPath(_ path: String, homePath: String) -> String? {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        guard !homePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let relativePath = String(path.dropFirst(path == "~" ? 1 : 2))
        guard !relativePath.isEmpty else { return homePath }
        return homePath.hasSuffix("/") ? homePath + relativePath : homePath + "/" + relativePath
    }

}
