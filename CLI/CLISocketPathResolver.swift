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
                let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
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

enum CLISocketPathSource: Equatable, Sendable {
    case explicitFlag
    case environment
    case implicitDefault
}

/// The observable result of resolving an implicit CLI socket path.
struct CLISocketPathResolution: Sendable {
    let source: CLISocketPathSource
    let requestedPath: String
    let candidatePaths: [String]
    let selectedPath: String?

    /// Whether resolution may proceed to the socket client.
    ///
    /// Explicit paths are intentionally not probed here: their identity is
    /// pinned and the normal client error must report the requested path.
    var hasLiveSocket: Bool {
        source != .implicitDefault || selectedPath != nil
    }

    /// Whether discovery selected a different path than the one the caller expected.
    var didReroute: Bool {
        guard let selectedPath else { return false }
        return !CLISocketPathResolver.pathsMatchForDiagnostics(requestedPath, selectedPath)
    }

    /// A user-facing diagnostic for an implicit discovery failure.
    var failureMessage: String {
        let header = String(
            localized: "cli.socket.error.discoveryFailed",
            defaultValue: "No live cmux socket found. Tried:"
        )
        let paths = candidatePaths.map { "  \($0)" }.joined(separator: "\n")
        return paths.isEmpty ? header : "\(header)\n\(paths)"
    }

    /// A user-facing notice explaining a deterministic implicit reroute.
    var rerouteNotice: String? {
        guard let selectedPath, didReroute else { return nil }
        let template = String(
            localized: "cli.socket.notice.rerouted",
            defaultValue: "cmux: default socket %@ is unavailable; using %@."
        )
        return String.localizedStringWithFormat(template, requestedPath, selectedPath)
    }
}

struct CLISocketPathResolver {
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

    private let environment: [String: String]
    private let bundleIdentifier: String?
    private let currentUserID: uid_t
    private let inspectSocketPathEntry: (String) -> SocketPathEntry
    private let socketAcceptsConnections: (String) -> Bool
    private let stateDirectory: URL

    /// Creates a resolver with explicit discovery inputs and filesystem probes.
    ///
    /// The inputs are captured once so command dispatch uses one deterministic
    /// resolution pass and tests can provide an isolated probe implementation.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Self.currentAppBundleIdentifier(),
        currentUserID: uid_t = getuid(),
        inspectSocketPathEntry: @escaping (String) -> SocketPathEntry = Self.inspectSocketPathEntry,
        socketAcceptsConnections: @escaping (String) -> Bool = Self.socketAcceptsConnections,
        fileManager: FileManager = .default,
        stateDirectory: URL? = nil
    ) {
        self.environment = environment
        self.bundleIdentifier = bundleIdentifier
        self.currentUserID = currentUserID
        self.inspectSocketPathEntry = inspectSocketPathEntry
        self.socketAcceptsConnections = socketAcceptsConnections
        self.stateDirectory = stateDirectory ?? CmuxStateDirectory.url(
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
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

    private var resolvedStableDefaultSocketPath: String {
        stateDirectory.appendingPathComponent(Self.stableSocketFileName, isDirectory: false).path
    }

    private func resolvedDefaultSocketPath() -> String {
        SocketPathMarkerFiles.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: false,
            stableSocketPath: resolvedStableDefaultSocketPath,
            debugSocketPath: Self.fallbackSocketPath,
            nightlySocketPath: Self.nightlySocketPath,
            stagingSocketPath: Self.stagingSocketPath
        )
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

    /// Resolves a socket using one ordered, liveness-aware discovery pass.
    ///
    /// Explicit flag and environment paths are deliberately returned verbatim and are
    /// never probed or rerouted. Implicit discovery only selects a path after a real
    /// non-blocking connect succeeds; a stale socket file is never handed to the client.
    func resolve(
        requestedPath: String,
        source: CLISocketPathSource
    ) -> CLISocketPathResolution {
        guard source == .implicitDefault else {
            return CLISocketPathResolution(
                source: source,
                requestedPath: requestedPath,
                candidatePaths: [requestedPath],
                selectedPath: requestedPath
            )
        }

        let candidates = Self.dedupe(candidatePaths(requestedPath: requestedPath))
        let selectedPath = candidates.first { path in
            canConnect(to: path)
        }
        return CLISocketPathResolution(
            source: source,
            requestedPath: requestedPath,
            candidatePaths: candidates,
            selectedPath: selectedPath
        )
    }

    private func candidatePaths(requestedPath: String) -> [String] {
        var candidates: [String] = []
        let variant = SocketPathMarkerFiles.variant(bundleIdentifier: bundleIdentifier, environment: environment)
        let ownDefaultPath = resolvedDefaultSocketPath()

        // Keep the current variant first. For a tagged debug CLI this is the
        // tag-specific socket; for the stable CLI it is the primary stable socket.
        candidates.append(ownDefaultPath)

        // A dead dev socket must not strand ambient commands. The stable primary
        // socket is the deterministic machine-wide fallback before any marker.
        candidates.append(resolvedStableDefaultSocketPath)

        // Markers are an ordered list, not a single pointer: the state-directory
        // marker and its legacy /tmp mirror can disagree after a reload.
        candidates.append(contentsOf: readLastSocketPaths(
            bundleIdentifier: bundleIdentifier,
            environment: environment
        ))
        // A dev process may be the last writer for its own marker while the
        // stable app's marker still names a user-scoped stable listener. Walk
        // those markers too, in deterministic order, rather than treating one
        // variant's file as the entire discovery state.
        candidates.append(contentsOf: readLastSocketPaths(
            bundleIdentifier: SocketPathMarkerFiles.stableBundleIdentifier,
            environment: [:]
        ))

        // Preserve legacy/user-scoped stable aliases after the primary and marker
        // candidates. They remain useful on machines migrating from older releases.
        candidates.append(contentsOf: implicitFallbackCandidatePaths(for: variant))

        // A caller that supplies a non-default implicit path still gets that path
        // tried, but it never displaces the current variant's own socket.
        if shouldIncludeImplicitRequestedPath(
            requestedPath,
            defaultPath: ownDefaultPath,
            variant: variant
        ) {
            candidates.append(requestedPath)
        }
        return candidates
    }

    private func shouldIncludeImplicitRequestedPath(
        _ requestedPath: String,
        defaultPath: String,
        variant: SocketPathVariant
    ) -> Bool {
        switch variant {
        case .stable:
            return true
        case .nightly, .staging, .dev:
            return Self.pathsMatch(requestedPath, defaultPath)
                || !Self.containsPath(resolvedStableImplicitDefaultPaths(), requestedPath)
        }
    }

    private func implicitFallbackCandidatePaths(for variant: SocketPathVariant) -> [String] {
        switch variant {
        case .stable, .nightly, .staging, .dev:
            return resolvedStableImplicitDefaultPaths()
        }
    }

    private func resolvedStableImplicitDefaultPaths() -> [String] {
        Self.dedupe([
            resolvedStableDefaultSocketPath,
            Self.legacyDefaultSocketPath,
            stateDirectory.appendingPathComponent("cmux-\(currentUserID).sock", isDirectory: false).path,
            Self.legacyUserScopedStableSocketPath(currentUserID: currentUserID),
        ])
    }

    private func readLastSocketPaths(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        let candidates = lastSocketPathFiles(bundleIdentifier: bundleIdentifier, environment: environment)
        var values: [String] = []
        for candidate in candidates {
            guard let contents = boundedMarkerContents(at: candidate) else { continue }
            if let value = Self.normalized(contents) {
                values.append(value)
            }
        }
        return values
    }

    private func isOwnedSocketFile(_ path: String) -> Bool {
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

    private func canConnect(to path: String) -> Bool {
        guard isOwnedSocketFile(path) else {
            return false
        }
        return socketAcceptsConnections(path)
    }

    private static func socketAcceptsConnections(_ path: String) -> Bool {
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
        guard path.utf8.count < maxLength else {
            return false
        }
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

    /// Reads at most one short socket marker without accepting unbounded input.
    private func boundedMarkerContents(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == currentUserID,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(SocketPathMarkerStore.maximumMarkerBytes)
        else {
            return nil
        }

        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: SocketPathMarkerStore.maximumMarkerBytes + 1),
              data.count <= SocketPathMarkerStore.maximumMarkerBytes
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

    /// Keeps diagnostic value semantics available to the result type without exposing
    /// the resolver's path-normalization implementation as public API.
    fileprivate static func pathsMatchForDiagnostics(_ lhs: String, _ rhs: String) -> Bool {
        pathsMatch(lhs, rhs)
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

    private func lastSocketPathFiles(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            directory: stateDirectory
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
        return SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
#else
        return SocketPathMarkerFiles.stableBundleIdentifier
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
