internal import CmuxCore
public import Foundation

// Drag-and-drop file upload onto the remote host over scp, with rollback of
// already-uploaded files on failure or cancellation. Faithful lift: scp argv
// composition, the `/tmp/cmux-drop-<uuid>` path shape, cleanup script text,
// and the completion/cancellation ordering (including the main-queue
// completion hop) are pinned legacy behavior. (The legacy no-operation
// convenience overload was dead code — the workspace model always passes an
// operation — and was dropped rather than re-created around an app type.)
extension RemoteSessionCoordinator {
    /// Uploads dropped local files to `/tmp/cmux-drop-*` paths on the remote
    /// host, completing on the main queue with the remote paths (or rolling
    /// back uploads and failing when cancelled).
    public func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: any RemoteTransferCancelling,
        completion: @escaping @Sendable (Result<[String], any Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(RemoteDropUploadError.unavailable))
                }
                return
            }

            do {
                try operation.throwIfCancelled()
                let remotePaths = try self.uploadDroppedFilesLocked(fileURLs, operation: operation)
                try operation.throwIfCancelled()
                DispatchQueue.main.async { [weak self] in
                    if operation.isCancelled {
                        guard let self else {
                            completion(.failure(operation.cancellationError))
                            return
                        }
                        self.queue.async { [weak self] in
                            self?.cleanupUploadedRemotePaths(remotePaths)
                            DispatchQueue.main.async {
                                completion(.failure(operation.cancellationError))
                            }
                        }
                    } else {
                        completion(.success(remotePaths))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func uploadDroppedFilesLocked(
        _ fileURLs: [URL],
        operation: any RemoteTransferCancelling
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var uploadedRemotePaths: [String] = []
        do {
            for localURL in fileURLs {
                try operation.throwIfCancelled()
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw RemoteDropUploadError.invalidFileURL
                }

                let remotePath = Self.remoteDropPath(for: normalizedLocalURL)
                uploadedRemotePaths.append(remotePath)
                var scpArgs: [String] = ["-q", "-o", "ControlMaster=no"]
                if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
                    scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
                }
                if let port = configuration.port {
                    scpArgs += ["-P", String(port)]
                }
                if let identityFile = configuration.identityFile,
                   !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scpArgs += ["-i", identityFile]
                }
                for option in scpSSHOptions {
                    scpArgs += ["-o", option]
                }
                scpArgs += [normalizedLocalURL.path, "\(configuration.destination):\(remotePath)"]

                let scpResult = try scpExec(arguments: scpArgs, timeout: 45, operation: operation)
                guard scpResult.status == 0 else {
                    let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ??
                        "scp exited \(scpResult.status)"
                    throw RemoteDropUploadError.uploadFailed(detail)
                }
            }
            return uploadedRemotePaths
        } catch {
            cleanupUploadedRemotePaths(uploadedRemotePaths)
            throw error
        }
    }

    /// The `/tmp/cmux-drop-<uuid>[.ext]` remote path a dropped local file
    /// uploads to (lowercased extension). Static and pinned by tests; also
    /// used by the foreground-SSH drop path.
    public static func remoteDropPath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        let extensionSuffix = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedSuffix = extensionSuffix.isEmpty ? "" : ".\(extensionSuffix.lowercased())"
        return "/tmp/cmux-drop-\(uuid.uuidString.lowercased())\(lowercasedSuffix)"
    }

    func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(\.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(cleanupScript.shellSingleQuoted)"
        _ = try? sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, cleanupCommand],
            timeout: 8
        )
    }
}
