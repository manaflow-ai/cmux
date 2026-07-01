import Darwin
import Foundation
import CmuxSettings

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
            if current.pathExtension == "app", let bundle = validBundle(at: current) {
                return bundle
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app", let bundle = validBundle(at: appURL) {
                    return bundle
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                return nil
            }
            current = parent
        }
    }

    private static func validBundle(at url: URL) -> Bundle? {
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        return bundle
    }
}

enum CLISocketPathSource {
    case explicitFlag
    case environment
    case implicitDefault
}

enum CLISocketPathResolver {
    enum SocketPathEntry {
        case missing
        case socket(ownerUserID: uid_t)
        case other(ownerUserID: uid_t)
        case inaccessible(errnoCode: Int32)
    }

    private static let stableSocketFileName = "cmux.sock"
    static let legacyDefaultSocketPath = "/tmp/cmux.sock"
    private static let fallbackSocketPath = "/tmp/cmux-debug.sock"
    private static let nightlySocketPath = "/tmp/cmux-nightly.sock"
    private static let stagingSocketPath = "/tmp/cmux-staging.sock"

    static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        SocketPathMarkerFiles.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: false,
            stableSocketPath: stableDefaultSocketPath,
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

    private static func userScopedStableSocketPath(currentUserID: uid_t = getuid()) -> String {
        stableSocketDirectoryURL()?
            .appendingPathComponent("cmux-\(currentUserID).sock", isDirectory: false)
            .path ?? legacyUserScopedStableSocketPath(currentUserID: currentUserID)
    }

    private static func legacyUserScopedStableSocketPath(currentUserID: uid_t = getuid()) -> String {
        "/tmp/cmux-\(currentUserID).sock"
    }

    static func isImplicitDefaultPath(
        _ path: String,
        bundleIdentifier: String? = currentAppBundleIdentifier(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        containsPath(
            knownImplicitDefaultPaths(bundleIdentifier: bundleIdentifier, environment: environment),
            path
        )
    }

    static func resolve(
        requestedPath: String,
        source: CLISocketPathSource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = currentAppBundleIdentifier(),
        currentUserID: uid_t = getuid(),
        inspectSocketPathEntry: (String) -> SocketPathEntry = inspectSocketPathEntry
    ) -> String {
        guard source == .implicitDefault else {
            return requestedPath
        }

        let variant = SocketPathMarkerFiles.variant(bundleIdentifier: bundleIdentifier, environment: environment)
        if case .stable = variant,
           canConnect(to: requestedPath, currentUserID: currentUserID, inspectSocketPathEntry: inspectSocketPathEntry) {
            return requestedPath
        }

        let candidates = dedupe(candidatePaths(
            requestedPath: requestedPath,
            environment: environment,
            bundleIdentifier: bundleIdentifier
        ))

        // Prefer sockets that are currently accepting connections.
        for path in candidates where canConnect(
            to: path,
            currentUserID: currentUserID,
            inspectSocketPathEntry: inspectSocketPathEntry
        ) {
            return path
        }

        // If the listener is still starting, prefer existing socket files.
        for path in candidates where isOwnedSocketFile(
            path,
            currentUserID: currentUserID,
            inspectSocketPathEntry: inspectSocketPathEntry
        ) {
            return path
        }

        return candidates.first ?? requestedPath
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
        if let last = readLastSocketPath(bundleIdentifier: bundleIdentifier, environment: environment) {
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
            return pathsMatch(requestedPath, defaultPath)
                || !containsPath(stableImplicitDefaultPaths(), requestedPath)
        }
    }

    private static func implicitFallbackCandidatePaths(for variant: SocketPathVariant) -> [String] {
        switch variant {
        case .stable:
            return stableImplicitDefaultPaths()
        case .nightly, .staging, .dev:
            return []
        }
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
            for name in entries where name.hasPrefix("cmux-debug-") && name.hasSuffix(".sock") {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { continue }
                if isKnownDefaultSocketPath(path) {
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
        if case .socket = inspectSocketPathEntry(path) {
            return true
        }
        return false
    }

    private static func isOwnedSocketFile(
        _ path: String,
        currentUserID: uid_t,
        inspectSocketPathEntry: (String) -> SocketPathEntry
    ) -> Bool {
        if case .socket(let ownerUserID) = inspectSocketPathEntry(path) {
            return ownerUserID == currentUserID
        }
        return false
    }

    private static func inspectSocketPathEntry(_ path: String) -> SocketPathEntry {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT {
                return .missing
            }
            return .inaccessible(errnoCode: errno)
        }
        if (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
            return .socket(ownerUserID: st.st_uid)
        }
        return .other(ownerUserID: st.st_uid)
    }

    private static func canConnect(
        to path: String,
        currentUserID: uid_t,
        inspectSocketPathEntry: (String) -> SocketPathEntry
    ) -> Bool {
        guard isOwnedSocketFile(
            path,
            currentUserID: currentUserID,
            inspectSocketPathEntry: inspectSocketPathEntry
        ) else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else { return false }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

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
        if result == 0 {
            return true
        }
        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EAGAIN || connectErrno == EWOULDBLOCK else {
            return false
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, 150) > 0 else {
            return false
        }
        guard (pollFD.revents & Int16(POLLOUT)) != 0 else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &socketError) { errorPointer in
            withUnsafeMutablePointer(to: &socketErrorLength) { lengthPointer in
                getsockopt(fd, SOL_SOCKET, SO_ERROR, errorPointer, lengthPointer)
            }
        }
        return optionResult == 0 && socketError == 0
    }

    private static func knownImplicitDefaultPaths(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        let variant = SocketPathMarkerFiles.variant(bundleIdentifier: bundleIdentifier, environment: environment)
        let defaultPath = defaultSocketPath(bundleIdentifier: bundleIdentifier, environment: environment)
        if case .stable = variant {
            return stableImplicitDefaultPaths()
        }
        return dedupe(
            [defaultPath] + stableImplicitDefaultPaths()
        )
    }

    private static func stableImplicitDefaultPaths() -> [String] {
        dedupe([
            stableDefaultSocketPath,
            legacyDefaultSocketPath,
            userScopedStableSocketPath(),
            legacyUserScopedStableSocketPath(),
        ])
    }

    private static func allKnownDefaultSocketPaths() -> Set<String> {
        Set(dedupe([
            stableDefaultSocketPath,
            legacyDefaultSocketPath,
            userScopedStableSocketPath(),
            legacyUserScopedStableSocketPath(),
            fallbackSocketPath,
            nightlySocketPath,
            stagingSocketPath,
        ]))
    }

    private static func isKnownDefaultSocketPath(_ path: String) -> Bool {
        containsPath(Array(allKnownDefaultSocketPaths()), path)
    }

    private static func containsPath(_ paths: [String], _ path: String) -> Bool {
        paths.contains { pathsMatch($0, path) }
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsForms = pathComparisonForms(lhs)
        let rhsForms = pathComparisonForms(rhs)
        return lhsForms.contains { lhsForm in
            rhsForms.contains { rhsForm in
                lhsForm == rhsForm
                    || lhsForm.caseInsensitiveCompare(rhsForm) == .orderedSame
            }
        }
    }

    private static func pathComparisonForms(_ path: String) -> [String] {
        let baseForms = [
            (path as NSString).standardizingPath,
            (path as NSString).resolvingSymlinksInPath,
        ]
        var forms = baseForms
        for form in baseForms {
            if form.hasPrefix("/private/tmp/") {
                forms.append("/tmp/" + String(form.dropFirst("/private/tmp/".count)))
            } else if form.hasPrefix("/tmp/") {
                forms.append("/private/tmp/" + String(form.dropFirst("/tmp/".count)))
            }
        }
        return dedupe(forms)
    }

    private static func lastSocketPathFiles(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            directory: stableSocketDirectoryURL()
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

    /// The directory holding the control socket and its marker files.
    ///
    /// Resolves to ``CmuxStateDirectory`` (`~/.local/state/cmux`), matching the
    /// app's `SocketControlSettings.stableSocketDirectoryURL()`. This keeps the
    /// CLI off the app's TCC-protected Application Support data on the agent hook
    /// path (https://github.com/manaflow-ai/cmux/issues/5146). The CLI is a
    /// composition root, so it names the concrete `FileManager.default` here.
    private static func stableSocketDirectoryURL() -> URL? {
        CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func socketDiscoveryDirectories() -> [String] {
        let stateSocketDirectory: String = stableSocketDirectoryURL()?.path ?? ""
        return dedupe([
            "/tmp",
            stateSocketDirectory,
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
