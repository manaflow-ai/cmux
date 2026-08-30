public import Foundation

/// Resolves the transport's on-disk state directory.
///
/// Multiple cmux builds share one macOS user Library (Mac apps are not
/// sandboxed), and dev builds speak to staging while release builds speak to
/// production. A single shared folder lets one build's staging trust keys
/// poison another build's production grant verification, and exposes one
/// build's cached state to every other (08-27 invisible-Mac incident).
/// Namespacing by bundle identifier AND broker host makes cross-build and
/// cross-environment reuse structurally impossible.
public enum IrxStateLocation {
    /// The pre-namespacing shared folder name; removed on sight because it
    /// held a plaintext identity key readable by every build.
    static let legacySharedFolderName = "cmux-irx"

    public static func directory(
        base: URL,
        bundleIdentifier: String?,
        brokerHost: String?
    ) -> URL {
        base
            .appendingPathComponent("cmux-transport", isDirectory: true)
            .appendingPathComponent(
                sanitized(bundleIdentifier, fallback: "unknown-bundle"),
                isDirectory: true
            )
            .appendingPathComponent(
                sanitized(brokerHost, fallback: "unknown-broker"),
                isDirectory: true
            )
    }

    /// Best-effort removal of the legacy shared directory. Running builds
    /// that still use it re-register on their next launch (cheap, and the
    /// namespaced path takes over), while the plaintext identity file stops
    /// existing immediately.
    public static func removeLegacySharedDirectory(base: URL) {
        try? FileManager.default.removeItem(
            at: base.appendingPathComponent(
                legacySharedFolderName, isDirectory: true)
        )
    }

    static func sanitized(_ raw: String?, fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        let cleaned = raw.lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || character == "." || character == "-" || character == "_"
                ? String(character) : "-"
        }.joined()
        // An all-dots component ("." / "..") is a path traversal, not a name.
        guard cleaned.contains(where: { $0 != "." }) else { return fallback }
        return String(cleaned.prefix(128))
    }
}
