@preconcurrency import Foundation

/// Resolves the pinned, downloadable Chromium runtime used by opt-in panes.
///
/// The manifest intentionally contains only URLs and metadata. The executable
/// is downloaded into cmux's application-support directory on first use and is
/// never checked into the repository. Keeping the version in source makes the
/// runtime reproducible and prevents a page or a settings file from selecting
/// an arbitrary executable.
struct ChromiumRuntimeManifest: Sendable {
    private static let productionVersion = "152.0.7977.42"

    let version: String
    let artifacts: [String: ChromiumRuntimeArtifact]

    /// The production manifest for the current macOS process architecture.
    ///
    /// Chrome for Testing publishes separate arm64 and x86_64 archives. The
    /// URLs are pinned to one revision; callers must not substitute a URL from
    /// page content or an untrusted configuration file.
    ///
    /// The full Chrome for Testing browser (not `chrome-headless-shell`) is
    /// pinned deliberately: the headless shell has no extensions subsystem,
    /// while the full browser under `--headless=new` loads unpacked
    /// extensions and matches the engine users run day to day.
    static let production = ChromiumRuntimeManifest(
        version: productionVersion,
        artifacts: [
            "arm64": ChromiumRuntimeArtifact(
                version: productionVersion,
                platform: "mac-arm64",
                downloadURL: URL(string: "https://storage.googleapis.com/chrome-for-testing-public/\(productionVersion)/mac-arm64/chrome-mac-arm64.zip")!,
                sha256: "c9a7b6bfb57731944990ffb7cafc17ae2f2a2e25ad1f145f45584d7b799d3ce8"
            ),
            "x86_64": ChromiumRuntimeArtifact(
                version: productionVersion,
                platform: "mac-x64",
                downloadURL: URL(string: "https://storage.googleapis.com/chrome-for-testing-public/\(productionVersion)/mac-x64/chrome-mac-x64.zip")!,
                sha256: "3bd9d6b077d67466ffff1b65e4292a255b953587dc6f4b72dfbd88df2cfd99e7"
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
