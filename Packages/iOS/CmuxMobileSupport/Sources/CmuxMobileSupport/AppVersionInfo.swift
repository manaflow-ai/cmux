public import Foundation

/// The running build's user-tellable version, assembled from the app bundle's
/// `Info.plist` so the in-app About row reports exactly which build a device is
/// running.
///
/// A release/TestFlight build reports a clean marketing version with its build
/// number, e.g. `1.0.0 (20260607031606)`. A DEBUG dogfood build additionally
/// appends the `--tag` and the short git SHA injected by `ios/scripts/reload.sh`
/// (the `CMUXDevTag` / `CMUXGitSHA` Info.plist keys), e.g.
/// `1.0.0 (123) · grid · a1b2c3d`, so two dev reloads are never indistinguishable.
///
/// The type is a pure value derived from a dictionary, so it is testable without
/// launching the app: pass a fixture dictionary and an explicit `isDevBuild`.
///
/// ```swift
/// let info = AppVersionInfo(
///     infoDictionary: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "123"],
///     isDevBuild: false
/// )
/// info.displayString // "1.0.0 (123)"
/// ```
public struct AppVersionInfo: Sendable, Equatable {
    /// The human marketing version (`CFBundleShortVersionString`), e.g. `1.0.0`.
    public let marketingVersion: String

    /// The monotonic build identifier (`CFBundleVersion`); empty when absent.
    public let buildNumber: String

    /// The dev `--tag` (`CMUXDevTag`); empty for release/TestFlight builds.
    public let devTag: String

    /// The short git SHA (`CMUXGitSHA`); empty for release/TestFlight builds.
    ///
    /// A trailing `+` (stamped by the reload script) marks an uncommitted tree.
    public let gitSHA: String

    /// Whether this is a development build, controlling whether the dev tag and
    /// SHA are appended to ``displayString``.
    public let isDevBuild: Bool

    /// Build a version info from an app bundle's info dictionary.
    ///
    /// - Parameters:
    ///   - infoDictionary: Typically `Bundle.main.infoDictionary`. Missing keys
    ///     degrade gracefully (marketing version falls back to `0.0.0`, the rest
    ///     to empty).
    ///   - isDevBuild: Whether the running build is a development build. The
    ///     caller passes the real `#if DEBUG` value; tests pass it explicitly so
    ///     both code paths are exercisable.
    public init(infoDictionary: [String: Any]?, isDevBuild: Bool) {
        func trimmedString(_ key: String) -> String {
            guard let value = infoDictionary?[key] as? String else { return "" }
            // Unexpanded build-setting placeholders (e.g. "$(CMUX_GIT_SHA)" when
            // a key was never overridden) are not user-meaningful; treat them as
            // empty so a release build shows nothing rather than a raw macro.
            if value.hasPrefix("$(") { return "" }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let marketing = trimmedString("CFBundleShortVersionString")
        self.marketingVersion = marketing.isEmpty ? "0.0.0" : marketing
        self.buildNumber = trimmedString("CFBundleVersion")
        self.devTag = trimmedString("CMUXDevTag")
        self.gitSHA = trimmedString("CMUXGitSHA")
        self.isDevBuild = isDevBuild
    }

    /// The full user-tellable version string for the About row.
    ///
    /// Release: `"1.0.0 (123)"` (or just `"1.0.0"` when there is no build
    /// number). Dev: the same, plus ` · <tag> · <sha>` for whichever of the dev
    /// tag and SHA are present.
    public var displayString: String {
        var base = marketingVersion
        if !buildNumber.isEmpty {
            base += " (\(buildNumber))"
        }
        guard isDevBuild else { return base }
        var suffixes: [String] = []
        if !devTag.isEmpty { suffixes.append(devTag) }
        if !gitSHA.isEmpty { suffixes.append(gitSHA) }
        guard !suffixes.isEmpty else { return base }
        return ([base] + suffixes).joined(separator: " · ")
    }

    /// The running app's version info, read from `Bundle.main`.
    ///
    /// `isDevBuild` is resolved from `#if DEBUG` at the call site, so a release
    /// build never appends dev metadata even if the keys somehow carried values.
    public static func current() -> AppVersionInfo {
        #if DEBUG
        let isDev = true
        #else
        let isDev = false
        #endif
        return AppVersionInfo(infoDictionary: Bundle.main.infoDictionary, isDevBuild: isDev)
    }
}
