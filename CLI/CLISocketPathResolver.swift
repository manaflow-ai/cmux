import Darwin
import Foundation
import CMUXSocketPathDomain

enum CLIExecutableLocator {
    static func currentExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buffer))
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            }
        }

        return Bundle.main.executableURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    static func enclosingAppBundle() -> Bundle? {
        enclosingAppBundle(startingAt: currentExecutableURL())
    }

    static func enclosingAppBundle(startingAt executableURL: URL?) -> Bundle? {
        guard let executableURL else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app", let bundle = Bundle(url: current) {
                return bundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let bundle = Bundle(url: appURL) {
                    return bundle
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                return nil
            }
            current = parent
        }
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

enum CLISocketPathResolver {
    private static let appSupportDirectoryName = "cmux"
    private static let stableSocketFileName = SocketPathMarkerFiles.releaseSocketFileName
    private static let legacyStableSocketFileName = SocketPathMarkerFiles.legacyReleaseSocketFileName
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = SocketPathMarkerFiles.defaultDebugSocketPath
    private static let nightlySocketPath = SocketPathMarkerFiles.defaultNightlySocketPath
    private static let stagingSocketPath = SocketPathMarkerFiles.defaultStagingSocketPath

    private enum SocketProbeResult {
        case cmux
        case notCmux
        case indeterminate
        case unavailable
    }

    static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        SocketPathMarkerFiles.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: false,
            stableSocketPath: stableDefaultSocketPath,
            appSupportDirectory: stableSocketDirectoryURL(),
            debugSocketPath: fallbackSocketPath,
            nightlySocketPath: nightlySocketPath,
            stagingSocketPath: stagingSocketPath
        )
    }

    private static var stableDefaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(
        _ path: String,
        bundleIdentifier: String? = currentAppBundleIdentifier(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        knownImplicitDefaultPaths(bundleIdentifier: bundleIdentifier, environment: environment).contains(path)
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = currentAppBundleIdentifier()
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(
            requestedPath: requestedPath,
            environment: environment,
            bundleIdentifier: bundleIdentifier
        ))
        var rejectedPaths: Set<String> = []

        // Prefer sockets that prove they speak the cmux protocol. Another
        // process can bind a Unix socket path and accept connections.
        for path in candidates {
            switch probeCmuxSocket(at: path) {
            case .cmux:
                return path
            case .notCmux:
                rejectedPaths.insert(path)
            case .indeterminate, .unavailable:
                break
            }
        }

        // If the listener is still starting, prefer existing socket files that
        // were not proven to be a different protocol.
        for path in candidates where !rejectedPaths.contains(path) && isSocketFile(path) {
            return path
        }

        return requestedPath
    }

    private static func candidatePaths(
        requestedPath: String,
        environment: [String: String],
        bundleIdentifier: String?
    ) -> [String] {
        var candidates: [String] = []
        let variant = SocketPathMarkerFiles.variant(bundleIdentifier: bundleIdentifier, environment: environment)
        let defaultPath = defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment)

        candidates.append(defaultPath)
        if let last = readLastSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            variant: variant
        ) {
            candidates.append(last)
        }
        if shouldIncludeImplicitRequestedPath(
            requestedPath,
            defaultPath: defaultPath,
            variant: variant
        ) {
            candidates.append(requestedPath)
        }
        candidates.append(contentsOf: implicitFallbackCandidatePaths(for: variant))
        if shouldDiscoverTaggedSockets(
            variant: variant,
            bundleIdentifier: bundleIdentifier,
            environment: environment
        ) {
            candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        }
        return candidates
    }

    private static func shouldIncludeImplicitRequestedPath(
        _ requestedPath: String,
        defaultPath: String,
        variant: SocketPathVariant
    ) -> Bool {
        switch variant {
        case .stable:
            return true
        case .nightly, .staging, .dev:
            return requestedPath == defaultPath || !stableImplicitDefaultPaths().contains(requestedPath)
        }
    }

    private static func implicitFallbackCandidatePaths(for variant: SocketPathVariant) -> [String] {
        switch variant {
        case .stable:
            return stableImplicitDefaultPaths()
        case .nightly(let slug):
            if let slug {
                return ["/tmp/cmux-nightly-\(slug).sock"]
            }
            return [nightlySocketPath]
        case .staging(let slug):
            if let slug {
                return ["/tmp/cmux-staging-\(slug).sock"]
            }
            return [stagingSocketPath]
        case .dev(let slug):
            if let slug {
                return [
                    "/tmp/cmux-debug-\(slug).sock",
                    "/tmp/cmux-\(slug).sock",
                ]
            }
            return [fallbackSocketPath]
        }
    }

    private static func shouldUseLastSocketPath(_ path: String, variant: SocketPathVariant) -> Bool {
        switch variant {
        case .stable:
            return !isNonReleaseVariantSocketName(URL(fileURLWithPath: path).lastPathComponent)
        case .nightly, .staging, .dev:
            return true
        }
    }

    private static func isNonReleaseVariantSocketName(_ name: String) -> Bool {
        guard name.hasSuffix(".sock") else { return false }
        if name == "cmux-staging.sock" || name.hasPrefix("cmux-staging-") {
            return true
        }
        if name == "cmux-nightly.sock" || name.hasPrefix("cmux-nightly-") {
            return true
        }
        if name == "cmux-debug.sock" || name.hasPrefix("cmux-debug-") {
            return true
        }
        if name.hasPrefix("cmux-"), name != "cmux.sock" {
            return true
        }
        if name == "com.cmuxterm.app.dev.sock" || name.hasPrefix("com.cmuxterm.app.dev.") {
            return true
        }
        if name == "com.cmuxterm.app.nightly.sock" || name.hasPrefix("com.cmuxterm.app.nightly.") {
            return true
        }
        if name == "com.cmuxterm.app.staging.sock" || name.hasPrefix("com.cmuxterm.app.staging.") {
            return true
        }
        return false
    }

    private static func shouldDiscoverTaggedSockets(
        variant: SocketPathVariant,
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> Bool {
        switch variant {
        case .dev(slug: nil):
            return true
        case .dev(slug: .some):
            let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return bundleId == SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
                && normalized(environment["CMUX_TAG"]) != nil
        case .stable, .nightly, .staging:
            return false
        }
    }

    private static func readLastSocketPath(
        bundleIdentifier: String?,
        environment: [String: String],
        variant: SocketPathVariant
    ) -> String? {
        let candidates = lastSocketPathFiles(bundleIdentifier: bundleIdentifier, environment: environment)
        for candidate in candidates {
            guard let data = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            if let value = normalized(data),
               shouldUseLastSocketPath(value, variant: variant) {
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
            for name in entries where isDiscoverableTaggedSocketName(name) {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if allKnownDefaultSocketPaths().contains(path) {
                    continue
                }
                let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
                discovered.append((path: path, mtime: modified))
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return dedupe(discovered.prefix(limit).map(\.path))
    }

    private static func isDiscoverableTaggedSocketName(_ name: String) -> Bool {
        guard name.hasSuffix(".sock") else { return false }
        return name.hasPrefix("cmux-debug-") ||
            name.hasPrefix("com.cmuxterm.app.dev.")
    }

    private static func isSocketFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
    }

    private static func probeCmuxSocket(at path: String) -> SocketProbeResult {
        guard isSocketFile(path) else { return .unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        defer { Darwin.close(fd) }
        configureSocketTimeouts(fd, timeout: 0.35)
        configureNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8CString.count <= maxLength else { return .unavailable }
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
        guard result == 0 else { return .unavailable }
        guard writeAll(Data("ping\n".utf8), to: fd) else { return .notCmux }
        guard let response = readFirstLine(from: fd) else {
            return .indeterminate
        }
        return response == "PONG" ? .cmux : .notCmux
    }

    private static func configureSocketTimeouts(_ fd: Int32, timeout: TimeInterval) {
        let clamped = max(timeout, 0.01)
        var socketTimeout = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - floor(clamped)) * 1_000_000)
        )
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func configureNoSigPipe(_ fd: Int32) {
#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
#else
        _ = fd
#endif
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
            return true
        }
    }

    private static func readFirstLine(from fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 128)
        while bytes.count < 512 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.contains(0x0A) { break }
        }
        guard !bytes.isEmpty,
              let response = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        return response
            .components(separatedBy: .newlines)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func knownImplicitDefaultPaths(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        dedupe(
            [defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment)]
                + stableImplicitDefaultPaths()
        )
    }

    private static func stableImplicitDefaultPaths() -> [String] {
        dedupe([
            stableDefaultSocketPath,
            legacyStableSocketPath,
            legacyDefaultSocketPath,
        ])
    }

    private static func allKnownDefaultSocketPaths() -> Set<String> {
        Set(dedupe([
            stableDefaultSocketPath,
            legacyStableSocketPath,
            legacyDefaultSocketPath,
            fallbackSocketPath,
            nightlySocketPath,
            stagingSocketPath,
        ]))
    }

    private static func lastSocketPathFiles(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            appSupportDirectory: stableSocketDirectoryURL()
        )
    }

    static func currentAppBundleIdentifier() -> String? {
        if let bundleIdentifier = CLIExecutableLocator.enclosingAppBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

#if DEBUG
        return "com.cmuxterm.app.debug"
#else
        return "com.cmuxterm.app"
#endif
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

    private static var legacyStableSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(legacyStableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
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
