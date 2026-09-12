@preconcurrency import Foundation

/// Resolves the pinned, downloadable Chromium runtime used by opt-in panes.
///
/// The manifest intentionally contains only URLs and metadata. The executable
/// is downloaded into cmux's application-support directory on first use and is
/// never checked into the repository. Keeping the version in source makes the
/// runtime reproducible and prevents a page or a settings file from selecting
/// an arbitrary executable.
struct ChromiumRuntimeManifest: Sendable {
    private static let productionVersion = "owl-chromium-66fc3593cef3"

    let version: String
    let artifacts: [String: ChromiumRuntimeArtifact]

    /// The production manifest for the current macOS process architecture.
    ///
    /// The reviewed OWL release publishes a native macOS arm64 Content Shell
    /// plus its Mojo runtime dylib. The URL and source commit are pinned; page
    /// content and settings cannot select an arbitrary executable.
    static let production = ChromiumRuntimeManifest(
        version: productionVersion,
        artifacts: [
            "arm64": ChromiumRuntimeArtifact(
                version: productionVersion,
                platform: "mac-arm64",
                downloadURL: URL(string: "https://github.com/manaflow-ai/chromium/releases/download/owl-chromium-66fc3593ce/owl-chromium-runtime-macos-arm64-66fc3593cef3.tar.gz")!,
                sha256: "d412d1f2193b36900dcf0ea3a2436b5d8cf30cdc678503b68ebd86c9d73dd92b"
            ),
        ]
    )

    /// Returns the artifact matching the host architecture, or `nil` when the
    /// current process architecture is not supported by the manifest.
    func artifact(for architecture: String = Self.processArchitecture) -> ChromiumRuntimeArtifact? {
        artifacts[architecture]
    }

    /// The normalized architecture spelling used by the manifest.
    static var processArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unsupported"
#endif
    }
}
