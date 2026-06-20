public import Darwin
public import Foundation

/// Pure resolution policy for the cmux control socket: where its path lives, which
/// ``SocketControlMode`` is in effect, and how environment overrides apply.
///
/// Every member is a pure function of its inputs (environment, bundle identifier, user id,
/// filesystem probes passed as closures), so the whole type is testable without a running
/// app or real filesystem. User-facing display strings live with the app target.
public struct SocketControlSettings {
    /// `UserDefaults` key persisting the user's chosen ``SocketControlMode``.
    public static let appStorageKey = "socketControlMode"
    /// Legacy `UserDefaults` key from the old boolean enabled/disabled model.
    public static let legacyEnabledKey = "socketControlEnabled"
    /// Environment key that, when truthy, permits honoring `CMUX_SOCKET_PATH` overrides.
    public static let allowSocketPathOverrideKey = "CMUX_ALLOW_SOCKET_OVERRIDE"
    /// Environment key carrying the socket password (highest-priority password source).
    public static let socketPasswordEnvKey = "CMUX_SOCKET_PASSWORD"
    /// Environment key carrying the dev build's launch tag.
    public static let launchTagEnvKey = "CMUX_TAG"
    /// Base bundle identifier shared by all debug builds.
    public static let baseDebugBundleIdentifier = "com.cmuxterm.app.debug"
    private static let stableSocketFileName = "cmux.sock"
    /// Legacy stable socket path used before the Application Support location.
    public static let legacyStableDefaultSocketPath = "/tmp/cmux.sock"

    /// The stable build's default socket path (within ``CmuxStateDirectory``, falling back to `/tmp`).
    public static var stableDefaultSocketPath: String {
        stableSocketFileURL()?.path ?? legacyStableDefaultSocketPath
    }

    /// The result of probing the stable default socket path on disk.
    public enum StableDefaultSocketPathEntry: Equatable, Sendable {
        /// Nothing exists at the path.
        case missing
        /// A socket owned by `ownerUserID` exists at the path.
        case socket(ownerUserID: uid_t)
        /// A non-socket file owned by `ownerUserID` exists at the path.
        case other(ownerUserID: uid_t)
        /// The path could not be inspected; `errnoCode` is the failure reason.
        case inaccessible(errnoCode: Int32)
    }

    private static func normalizeMode(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func parseMode(_ raw: String) -> SocketControlMode? {
        switch normalizeMode(raw) {
        case "off":
            return .off
        case "cmuxonly":
            return .cmuxOnly
        case "automation":
            return .automation
        case "password":
            return .password
        case "allowall", "openaccess", "fullopenaccess":
            return .allowAll
        // Legacy values from the old socket mode model.
        case "notifications":
            return .automation
        case "full":
            return .allowAll
        default:
            return nil
        }
    }

    /// Maps a persisted raw mode value to the current ``SocketControlMode``.
    /// - Parameter raw: The persisted string (possibly a legacy value).
    /// - Returns: The mapped mode, or ``defaultMode`` if unrecognized.
    public static func migrateMode(_ raw: String) -> SocketControlMode {
        parseMode(raw) ?? defaultMode
    }

    /// The mode applied when nothing is configured.
    public static var defaultMode: SocketControlMode {
        return .cmuxOnly
    }

    @usableFromInline static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    /// The dev launch tag from the environment, trimmed, or `nil` when unset/empty.
    /// - Parameter environment: The process environment.
    /// - Returns: The launch tag, or `nil`.
    public static func launchTag(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[launchTagEnvKey] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether an untagged base debug build should be blocked from launching.
    ///
    /// Untagged debug builds share a bundle id and socket with other agents, so they are
    /// blocked outside of test runs. Tagged debug builds and tests are always allowed.
    public static func shouldBlockUntaggedDebugLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild
    ) -> Bool {
        guard isDebugBuild else { return false }
        if isRunningUnderXCTest(environment: environment) {
            return false
        }
        // XCUITest launches the app as a separate process without XCTest env vars,
        // so isRunningUnderXCTest() misses it. Check for any CMUX_UI_TEST_ env var.
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return false
        }

        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return false
        }

        if bundleIdentifier.hasPrefix("\(baseDebugBundleIdentifier).") {
            return false
        }

        guard bundleIdentifier == baseDebugBundleIdentifier else {
            return false
        }

        return launchTag(environment: environment) == nil
    }

    /// Whether the process appears to be running under XCTest.
    /// - Parameter environment: The process environment.
    /// - Returns: `true` if XCTest indicators are present.
    public static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        let indicators = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundle",
            "XCInjectBundleInto",
        ]
        if indicators.contains(where: { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    /// The control-socket path to use, honoring `CMUX_SOCKET_PATH` overrides only when safe.
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        let fallback = defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: isDebugBuild,
            currentUserID: currentUserID,
            probeStableDefaultPathEntry: probeStableDefaultPathEntry
        )

        guard let override = environment["CMUX_SOCKET_PATH"], !override.isEmpty else {
            return fallback
        }

        if shouldReserveStableSocketPath(bundleIdentifier: bundleIdentifier, isDebugBuild: isDebugBuild),
           isStableReleaseSocketPath(override, currentUserID: currentUserID) {
            return fallback
        }

        if isTaggedDevBuild(bundleIdentifier: bundleIdentifier),
           !isTruthy(environment[allowSocketPathOverrideKey]),
           !pathsMatch(override, fallback) {
            return fallback
        }

        if shouldHonorSocketPathOverride(
            environment: environment,
            bundleIdentifier: bundleIdentifier,
            isDebugBuild: isDebugBuild
        ) {
            return override
        }

        return fallback
    }

    /// The socket path to reserve before the listener starts, reclaiming the stable path when safe.
    public static func initialSocketPathBeforeListenerStart(
        preferredPath: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isDebugBuild: Bool = SocketControlSettings.isDebugBuild,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry,
        stableDefaultSocketCanBeReclaimed: (String) -> Bool = { _ in true }
    ) -> String {
        guard !isDebugBuild,
              normalizedBundleIdentifier(bundleIdentifier) == "com.cmuxterm.app",
              isStableReleaseSocketPath(preferredPath, currentUserID: currentUserID) else {
            return preferredPath
        }

        let userScopedPath = userScopedStableSocketPath(currentUserID: currentUserID)
        if pathsMatch(preferredPath, userScopedPath) {
            return preferredPath
        }

        switch probeStableDefaultPathEntry(preferredPath) {
        case .missing:
            return stableDefaultSocketCanBeReclaimed(preferredPath)
                ? preferredPath
                : userScopedPath
        case .socket(let ownerUserID) where ownerUserID == currentUserID:
            return userScopedPath
        case .socket, .other, .inaccessible:
            return preferredPath
        }
    }

    /// Whether two socket paths refer to the same socket, accounting for `/tmp` aliases and symlinks.
    public static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsForms = socketPathComparisonForms(lhs)
        let rhsForms = socketPathComparisonForms(rhs)
        return lhsForms.contains { lhsForm in
            rhsForms.contains { rhsForm in
                socketPathStringsMatch(lhsForm, rhsForm)
            }
        }
    }

    private static func socketPathStringsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func socketPathComparisonForms(_ path: String) -> [String] {
        let standardizedPath = (path as NSString).standardizingPath
        return dedupe([
            standardizedPath,
            canonicalSocketPath(path),
            privateTmpAlias(for: standardizedPath),
        ].compactMap(\.self))
    }

    private static func privateTmpAlias(for path: String) -> String? {
        if path == "/private/tmp" {
            return "/tmp"
        }
        if path.hasPrefix("/private/tmp/") {
            return "/tmp/" + path.dropFirst("/private/tmp/".count)
        }
        if path == "/tmp" {
            return "/private/tmp"
        }
        if path.hasPrefix("/tmp/") {
            return "/private/tmp/" + path.dropFirst("/tmp/".count)
        }
        return nil
    }

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }

    private static func canonicalSocketPath(_ path: String, visitedSymlinks: Set<String> = []) -> String? {
        let standardizedPath = (path as NSString).standardizingPath
        let url = URL(fileURLWithPath: standardizedPath)
        let resolvedParent = (
            (url.deletingLastPathComponent().path as NSString).resolvingSymlinksInPath as NSString
        ).standardizingPath
        let resolvedPath = (resolvedParent as NSString).appendingPathComponent(url.lastPathComponent)
        if isSymbolicLink(at: standardizedPath),
           let targetPath = symbolicLinkTarget(at: standardizedPath, resolvedParent: resolvedParent) {
            guard !visitedSymlinks.contains(resolvedPath), visitedSymlinks.count < 64 else {
                return nil
            }
            return canonicalSocketPath(
                targetPath,
                visitedSymlinks: visitedSymlinks.union([resolvedPath])
            )
        }
        return resolvedPath
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    private static func symbolicLinkTarget(at path: String, resolvedParent: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[Int(length)] = 0
        let target = String(cString: buffer)
        if target.hasPrefix("/") {
            return target
        }
        return (resolvedParent as NSString).appendingPathComponent(target)
    }

    private static func shouldReserveStableSocketPath(bundleIdentifier: String?, isDebugBuild: Bool) -> Bool {
        if isDebugBuild { return true }
        return normalizedBundleIdentifier(bundleIdentifier) != "com.cmuxterm.app"
    }

    private static func isStableReleaseSocketPath(_ path: String, currentUserID: uid_t) -> Bool {
        guard let candidatePath = canonicalSocketPath(path) else {
            return true
        }
        return [
            stableDefaultSocketPath,
            userScopedStableSocketPath(currentUserID: currentUserID),
            legacyStableDefaultSocketPath,
            legacyUserScopedStableSocketPath(currentUserID: currentUserID),
        ].contains { stablePath in
            canonicalSocketPath(stablePath)
                .map { socketPathStringsMatch(candidatePath, $0) }
                ?? pathsMatch(path, stablePath)
        }
    }

    /// The per-user stable socket path (`cmux-<uid>.sock` in ``CmuxStateDirectory``, `/tmp` fallback).
    public static func userScopedStableSocketPath(currentUserID: uid_t = getuid()) -> String {
        stableSocketDirectoryURL()?
            .appendingPathComponent("cmux-\(currentUserID).sock", isDirectory: false)
            .path ?? "/tmp/cmux-\(currentUserID).sock"
    }

    /// The legacy `/tmp` per-user stable socket path.
    public static func legacyUserScopedStableSocketPath(currentUserID: uid_t = getuid()) -> String {
        "/tmp/cmux-\(currentUserID).sock"
    }

    /// The stable default socket path, falling back to the per-user path when the shared one is taken.
    public static func resolvedStableDefaultSocketPath(
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        switch probeStableDefaultPathEntry(stableDefaultSocketPath) {
        case .missing:
            return stableDefaultSocketPath
        case .socket(let ownerUserID) where ownerUserID == currentUserID:
            return stableDefaultSocketPath
        case .socket, .other, .inaccessible:
            return userScopedStableSocketPath(currentUserID: currentUserID)
        }
    }

    /// Whether a `CMUX_SOCKET_PATH` override should be honored for this build.
    public static func shouldHonorSocketPathOverride(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> Bool {
        if isTruthy(environment[allowSocketPathOverrideKey]) {
            return true
        }
        if inheritedBundleIdentifierConflicts(environment: environment, bundleIdentifier: bundleIdentifier) {
            return false
        }
        if isDebugLikeBundleIdentifier(bundleIdentifier) || isStagingBundleIdentifier(bundleIdentifier) {
            return true
        }
        return isDebugBuild
    }

    private static func inheritedBundleIdentifierConflicts(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> Bool {
        guard let inheritedBundleIdentifier = normalizedBundleIdentifier(environment["CMUX_BUNDLE_ID"]),
              let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else {
            return false
        }
        return inheritedBundleIdentifier != bundleIdentifier
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the bundle identifier is a debug build identifier.
    public static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
    }

    /// Whether the bundle identifier is a tagged DEV build (`com.cmuxterm.app.debug.<tag>`).
    public static func isTaggedDevBuild(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix("\(baseDebugBundleIdentifier).")
    }

    /// Whether the bundle identifier is a staging build identifier.
    public static func isStagingBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.staging"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
    }

    /// The directory holding the control socket and its marker files.
    ///
    /// Resolves to ``CmuxStateDirectory`` (`~/.local/state/cmux`) rather than
    /// Application Support: the separately-signed `cmux` CLI connects to this
    /// socket on every agent hook, and a different-identity process reaching into
    /// the app's Application Support data triggers the macOS Sequoia "access data
    /// from other apps" prompt (https://github.com/manaflow-ai/cmux/issues/5146).
    public static func stableSocketDirectoryURL(fileManager: FileManager = .default) -> URL? {
        CmuxStateDirectory.url(homeDirectory: fileManager.homeDirectoryForCurrentUser)
    }

    /// The stable control socket file URL (within ``CmuxStateDirectory``), if it can be resolved.
    public static func stableSocketFileURL(fileManager: FileManager = .default) -> URL? {
        stableSocketDirectoryURL(fileManager: fileManager)?
            .appendingPathComponent(stableSocketFileName, isDirectory: false)
    }

    @usableFromInline static func inspectStableDefaultSocketPathEntry(_ path: String) -> StableDefaultSocketPathEntry {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let errnoCode = errno
            if errnoCode == ENOENT {
                return .missing
            }
            return .inaccessible(errnoCode: errnoCode)
        }

        let fileType = st.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFSOCK) {
            return .socket(ownerUserID: st.st_uid)
        }
        return .other(ownerUserID: st.st_uid)
    }

    /// Whether a raw string is a truthy flag value (`1`/`true`/`yes`/`on`).
    public static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    /// The `CMUX_SOCKET_ENABLE` override as a tri-state (`true`/`false`/`nil` when unset/invalid).
    public static func envOverrideEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment["CMUX_SOCKET_ENABLE"], !raw.isEmpty else {
            return nil
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// The `CMUX_SOCKET_MODE` override as a ``SocketControlMode``, or `nil` when unset/invalid.
    public static func envOverrideMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode? {
        guard let raw = environment["CMUX_SOCKET_MODE"], !raw.isEmpty else {
            return nil
        }
        return parseMode(raw)
    }

    /// The effective mode after applying `CMUX_SOCKET_ENABLE`/`CMUX_SOCKET_MODE` overrides.
    /// - Parameters:
    ///   - userMode: The user's configured mode.
    ///   - environment: The process environment.
    /// - Returns: The mode to actually apply.
    public static func effectiveMode(
        userMode: SocketControlMode,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SocketControlMode {
        if let overrideEnabled = envOverrideEnabled(environment: environment) {
            if !overrideEnabled {
                return .off
            }
            if let overrideMode = envOverrideMode(environment: environment) {
                return overrideMode
            }
            return userMode == .off ? .cmuxOnly : userMode
        }

        if let overrideMode = envOverrideMode(environment: environment) {
            return overrideMode
        }

        return userMode
    }
}
