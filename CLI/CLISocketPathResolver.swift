import Darwin
import Foundation

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
    private static let nightlySocketPath = "/tmp/cmux-nightly.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"
    private static let legacyLastSocketPathFile = "/tmp/cmux-last-socket-path"

    private enum SocketPathVariant: Equatable {
        case stable
        case nightly(slug: String?)
        case staging(slug: String?)
        case dev(slug: String?)

        var lastSocketPathFileName: String {
            switch self {
            case .stable:
                return CLISocketPathResolver.lastSocketPathFileName
            case .nightly(let slug):
                if let slug {
                    return "nightly-\(slug)-last-socket-path"
                }
                return "nightly-last-socket-path"
            case .staging(let slug):
                if let slug {
                    return "staging-\(slug)-last-socket-path"
                }
                return "staging-last-socket-path"
            case .dev(let slug):
                if let slug {
                    return "dev-\(slug)-last-socket-path"
                }
                return "dev-last-socket-path"
            }
        }

        var tmpLastSocketPathFile: String {
            switch self {
            case .stable:
                return CLISocketPathResolver.legacyLastSocketPathFile
            case .nightly(let slug):
                if let slug {
                    return "/tmp/cmux-nightly-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-nightly-last-socket-path"
            case .staging(let slug):
                if let slug {
                    return "/tmp/cmux-staging-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-staging-last-socket-path"
            case .dev(let slug):
                if let slug {
                    return "/tmp/cmux-dev-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-dev-last-socket-path"
            }
        }

        var isDev: Bool {
            if case .dev = self { return true }
            return false
        }
    }

    static var defaultSocketPath: String {
        defaultSocketPath(bundleIdentifier: currentAppBundleIdentifier())
    }

    static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        switch socketPathVariant(bundleIdentifier: bundleIdentifier, environment: environment) {
        case .stable:
            return stableDefaultSocketPath
        case .nightly(let slug):
            if let slug {
                return "/tmp/cmux-nightly-\(slug).sock"
            }
            return nightlySocketPath
        case .staging(let slug):
            if let slug {
                return "/tmp/cmux-\(slug).sock"
            }
            return stagingSocketPath
        case .dev(let slug):
            if let slug {
                return "/tmp/cmux-debug-\(slug).sock"
            }
            return fallbackSocketPath
        }
    }

    private static var stableDefaultSocketPath: String {
        let stablePath: String? = stableSocketDirectoryURL()?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
            .path
        return stablePath ?? legacyDefaultSocketPath
    }

    static func isImplicitDefaultPath(_ path: String) -> Bool {
        isImplicitDefaultPath(path, bundleIdentifier: currentAppBundleIdentifier())
    }

    static func isImplicitDefaultPath(
        _ path: String,
        bundleIdentifier: String?,
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

    private static func candidatePaths(
        requestedPath: String,
        environment: [String: String],
        bundleIdentifier: String?
    ) -> [String] {
        var candidates: [String] = []
        let variant = socketPathVariant(bundleIdentifier: bundleIdentifier, environment: environment)

        if let tag = normalized(environment["CMUX_TAG"]),
           let slug = sanitizeSocketSlug(tag) {
            candidates.append("/tmp/cmux-debug-\(slug).sock")
            candidates.append("/tmp/cmux-\(slug).sock")
        }

        candidates.append(defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment))
        if let last = readLastSocketPath(bundleIdentifier: bundleIdentifier, environment: environment) {
            candidates.append(last)
        }
        candidates.append(requestedPath)
        candidates.append(contentsOf: knownImplicitDefaultPaths(bundleIdentifier: bundleIdentifier, environment: environment))
        if variant.isDev {
            candidates.append(contentsOf: discoverTaggedSockets(limit: 12))
        }
        return candidates
    }

    private static func readLastSocketPath(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> String? {
        let candidates = lastSocketPathFiles(bundleIdentifier: bundleIdentifier, environment: environment)
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

    private static func sanitizeSocketSlug(_ raw: String) -> String? {
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    private static func socketPathVariant(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> SocketPathVariant {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleId == "com.cmuxterm.app.nightly" {
            return .nightly(slug: nil)
        }
        if bundleId.hasPrefix("com.cmuxterm.app.nightly.") {
            return .nightly(slug: bundleSuffixSlug(bundleId, prefix: "com.cmuxterm.app.nightly."))
        }
        if bundleId == "com.cmuxterm.app.staging" {
            return .staging(slug: nil)
        }
        if bundleId.hasPrefix("com.cmuxterm.app.staging.") {
            return .staging(slug: bundleSuffixSlug(bundleId, prefix: "com.cmuxterm.app.staging."))
        }
        if bundleId == "com.cmuxterm.app.debug" {
            if let tag = normalized(environment["CMUX_TAG"]),
               let slug = sanitizeSocketSlug(tag) {
                return .dev(slug: slug)
            }
            return .dev(slug: nil)
        }
        if bundleId.hasPrefix("com.cmuxterm.app.debug.") {
            return .dev(slug: bundleSuffixSlug(bundleId, prefix: "com.cmuxterm.app.debug."))
        }
        return .stable
    }

    private static func bundleSuffixSlug(_ bundleIdentifier: String, prefix: String) -> String? {
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        return sanitizeSocketSlug(suffix)
    }

    private static func knownImplicitDefaultPaths(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        let variant = socketPathVariant(
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
        switch variant {
        case .stable:
            return dedupe([
                defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment),
                stableDefaultSocketPath,
                legacyDefaultSocketPath,
            ])
        case .nightly, .staging, .dev:
            return [defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment)]
        }
    }

    private static func allKnownDefaultSocketPaths() -> Set<String> {
        Set(dedupe([
            stableDefaultSocketPath,
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
        let variant = socketPathVariant(bundleIdentifier: bundleIdentifier, environment: environment)
        var candidates: [String] = []
        if let appSupportPath = stableSocketDirectoryURL()?
            .appendingPathComponent(variant.lastSocketPathFileName, isDirectory: false)
            .path {
            candidates.append(appSupportPath)
        }
        candidates.append(variant.tmpLastSocketPathFile)
        return dedupe(candidates)
    }

    static func currentAppBundleIdentifier() -> String? {
        if let bundleIdentifier = enclosingAppBundle()?.bundleIdentifier?
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

    private static func enclosingAppBundle() -> Bundle? {
        guard let executableURL = CLIExecutableLocator.currentExecutableURL() else {
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

            guard let parent = CLIExecutableLocator.parentSearchURL(for: current) else {
                return nil
            }
            current = parent
        }
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
