import Darwin
import Foundation

enum CLISocketEnvironment {
    static func socketPath(in environment: [String: String]) throws -> String? {
        let socketPath = normalized(environment["CMUX_SOCKET_PATH"])
        let legacySocketPath = normalized(environment["CMUX_SOCKET"])
        if let socketPath, let legacySocketPath, socketPath != legacySocketPath {
            throw CLIError(message: "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET.")
        }
        return socketPath ?? legacySocketPath
    }

    static func socketPathForTelemetry(in environment: [String: String]) -> String? {
        normalized(environment["CMUX_SOCKET_PATH"]) ?? normalized(environment["CMUX_SOCKET"])
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "cmux"
    private static let stableSocketFileName = "cmux.sock"
    private static let lastSocketPathFileName = "last-socket-path"
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = "/tmp/cmux-debug.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/cmux-last-socket-path"

    static var defaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        path == defaultSocketPath || path == legacyDefaultSocketPath
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(requestedPath: requestedPath, environment: environment))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(to: path) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(requestedPath: String, environment: [String: String]) -> [String] {
        var candidates: [String] = []

        if let tag = normalized(environment["CMUX_TAG"]) {
            let slug = sanitizeTagSlug(tag)
            candidates.append("/tmp/cmux-debug-\(slug).sock")
            candidates.append("/tmp/cmux-\(slug).sock")
        }

        candidates.append(requestedPath)
        candidates.append(defaultSocketPath)
        candidates.append(legacyDefaultSocketPath)
        candidates.append(fallbackSocketPath)
        candidates.append(stagingSocketPath)
        candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        if let last = readLastSocketPath() {
            candidates.append(last)
        }
        return candidates
    }

    private static func readLastSocketPath() -> String? {
        let primaryCandidate: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(lastSocketPathFileName, isDirectory: false)
            .path
        let candidates = [primaryCandidate, legacyLastSocketPathFile].compactMap { $0 }

        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data) {
                return value
            }
        }
        return nil
    }

    private static func discoverTaggedSockets(limit: Int) -> [String] {
        var discovered: [(path: String, mtime: TimeInterval)] = []
        for directory in socketDiscoveryDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            discovered.reserveCapacity(min(limit, discovered.count + entries.count))
            for name in entries where name.hasPrefix("cmux") && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if path == defaultSocketPath || path == legacyDefaultSocketPath || path == fallbackSocketPath || path == stagingSocketPath {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func canConnect(to path: String) -> Bool {
        guard isSocketFile(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableSocketDirectoryURL() -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportDirectory.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let appSupportSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            appSupportSocketDirectory,
        ])
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }
}
