internal import Foundation
internal import Darwin

extension SocketTransport {
    /// Binds `socket` as the listener at `path`, preparing the path first.
    ///
    /// On success the bound socket inode's identity is captured for later
    /// ownership checks.
    ///
    /// - Parameters:
    ///   - socket: The unbound listener socket descriptor.
    ///   - path: The Unix-domain socket path to bind.
    ///   - canReplaceRefusedSocket: Whether a connection-refused socket file at
    ///     the path may be unlinked first (see ``SocketPathLockAcquisition``).
    /// - Returns: The bind outcome, including the bound inode's
    ///   ``SocketPathIdentity`` on success.
    public func bindListenerSocket(
        _ socket: Int32,
        path: String,
        canReplaceRefusedSocket: Bool
    ) -> SocketBindAttemptResult {
        if let errnoCode = ensureSocketParentDirectoryExists(path: path) {
            return .failure(
                path: path,
                failure: SocketStageFailure(stage: "create_directory", errnoCode: errnoCode)
            )
        }
        if let preparationFailure = prepareSocketPathForBind(
            path,
            canReplaceRefusedSocket: canReplaceRefusedSocket
        ) {
            return .failure(path: path, failure: preparationFailure)
        }

        guard let bindResult = bindUnixSocket(socket, path: path) else {
            return .pathTooLong(path: path)
        }
        guard bindResult >= 0 else {
            return .failure(
                path: path,
                failure: SocketStageFailure(stage: "bind", errnoCode: errno)
            )
        }
        let identityResult = pathIdentityResult(at: path)
        if let identity = identityResult.identity {
            return .success(path: path, identity: identity)
        }
        return .failure(
            path: path,
            failure: SocketStageFailure(
                stage: "stat_bound_path",
                errnoCode: identityResult.errnoCode ?? EIO
            )
        )
    }

    /// Clears `path` for a fresh bind, or returns the blocking stage failure.
    ///
    /// Existing non-socket files are never deleted. An existing socket is
    /// probed: stale sockets are unlinked; refused sockets are unlinked only
    /// when `canReplaceRefusedSocket` proves a prior owner left them behind;
    /// live or indeterminate sockets always block the bind.
    ///
    /// - Parameters:
    ///   - path: The socket path to prepare.
    ///   - canReplaceRefusedSocket: Whether a connection-refused socket file
    ///     may be unlinked.
    /// - Returns: Nil when the path is clear, or the blocking ``SocketStageFailure``.
    public func prepareSocketPathForBind(
        _ path: String,
        canReplaceRefusedSocket: Bool = false
    ) -> SocketStageFailure? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return errno == ENOENT ? nil : SocketStageFailure(stage: "stat_existing_path", errnoCode: errno)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return SocketStageFailure(stage: "existing_path", errnoCode: EEXIST)
        }
        switch pathProbeResult(at: path) {
        case .stale:
            break
        case .refused:
            guard canReplaceRefusedSocket else {
                return SocketStageFailure(stage: "bind", errnoCode: EADDRINUSE)
            }
        case .connected, .occupiedOrIndeterminate:
            return SocketStageFailure(stage: "bind", errnoCode: EADDRINUSE)
        }
        if unlink(path) != 0, errno != ENOENT {
            return SocketStageFailure(stage: "unlink", errnoCode: errno)
        }
        return nil
    }

    /// Creates the socket's parent directory (mode 0700) when missing; returns
    /// the failing `errno` otherwise.
    func ensureSocketParentDirectoryExists(path: String) -> Int32? {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return nil
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain {
                return Int32(error.code)
            }
            return EIO
        }
    }

    /// Raw `bind(2)`; nil when the path does not fit in `sockaddr_un`.
    func bindUnixSocket(_ socket: Int32, path: String) -> Int32? {
        guard var addr = unixSocketAddress(path: path) else { return nil }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
