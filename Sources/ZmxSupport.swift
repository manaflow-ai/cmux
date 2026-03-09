import Foundation

// MARK: - Settings

/// UserDefaults-backed zmx persistence settings.
enum ZmxPersistenceSettings {
    static let enabledKey = "zmxPersistenceEnabled"
    static let killOnCloseKey = "zmxKillOnWorkspaceClose"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var killOnWorkspaceClose: Bool {
        UserDefaults.standard.object(forKey: killOnCloseKey) as? Bool ?? true
    }
}

// MARK: - Session Naming

/// Deterministic zmx session name derivation from workspace stable ID.
enum ZmxSessionNaming {
    /// Generate a session name: "cmux-{8-char-hash}-{index}"
    /// Must stay under 46 characters (zmx IPC limit).
    static func sessionName(stableId: String, panelIndex: Int) -> String {
        let hash = stableId.replacingOccurrences(of: "-", with: "").prefix(8)
        return "cmux-\(hash)-\(panelIndex)"
    }

    /// Extract the panel index from a zmx session name.
    static func parseIndex(from sessionName: String) -> Int? {
        guard let lastDash = sessionName.lastIndex(of: "-") else { return nil }
        let suffix = sessionName[sessionName.index(after: lastDash)...]
        return Int(suffix)
    }
}

// MARK: - Session Probing

/// Non-blocking zmx daemon session probing over Unix sockets.
enum ZmxSessionProbe {
    /// Resolve the zmx socket directory.
    static func socketDir() -> String {
        if let dir = ProcessInfo.processInfo.environment["ZMX_DIR"] {
            return dir
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            return "\(xdg)/zmx"
        }
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return "\(tmpdir)/zmx-\(getuid())"
    }

    /// Check if a zmx session is alive by probing its Unix socket.
    /// Non-blocking connect + poll with 200ms timeout.
    static func isSessionAlive(_ sessionName: String) -> Bool {
        let dir = socketDir()
        let socketPath = "\(dir)/\(sessionName).sock"

        // sun_path limit is typically 104 bytes on macOS
        guard socketPath.utf8.count < 104 else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBytes = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                _ = strncpy(pathBytes, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        // Poll for connection
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, 200)
        guard pollResult > 0 else { return false }

        // Check SO_ERROR
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        return soError == 0
    }

    /// Check if the zmx binary is available on PATH (including common install locations).
    static func isZmxAvailable() -> Bool {
        // Check hardcoded common locations first
        let commonPaths = [
            "/opt/homebrew/bin/zmx",
            "/usr/local/bin/zmx",
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }

        // Fall back to PATH scan
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let dirs = pathEnv.split(separator: ":").map(String.init)
        for dir in dirs {
            let full = "\(dir)/zmx"
            if FileManager.default.isExecutableFile(atPath: full) {
                return true
            }
        }
        return false
    }

    /// Kill a zmx session by sending a Kill IPC message (tag=5) via Unix socket.
    static func killSession(_ sessionName: String) {
        let dir = socketDir()
        let socketPath = "\(dir)/\(sessionName).sock"

        guard socketPath.utf8.count < 104 else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBytes = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                _ = strncpy(pathBytes, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return }

        // IPC Kill message: 4-byte LE length (1) + 1-byte tag (5)
        var msg: [UInt8] = [1, 0, 0, 0, 5]
        _ = send(fd, &msg, msg.count, 0)
    }
}
