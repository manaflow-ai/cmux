@preconcurrency import Foundation

/// Resolves the pinned, downloadable Chromium runtime used by opt-in panes.
///
/// The manifest intentionally contains only URLs and metadata. The executable
/// is downloaded into cmux's application-support directory on first use and is
/// never checked into the repository. Keeping the version in source makes the
/// runtime reproducible and prevents a page or a settings file from selecting
/// an arbitrary executable.
struct ChromiumRuntimeManifest: Sendable {
    let version: String
    let artifacts: [String: ChromiumRuntimeArtifact]

    /// Creates a manifest from an explicit artifact table.
    ///
    /// - Parameters:
    ///   - version: Chromium for Testing version represented by the table.
    ///   - artifacts: One artifact per supported macOS architecture.
    init(version: String, artifacts: [String: ChromiumRuntimeArtifact]) {
        self.version = version
        self.artifacts = artifacts
    }

    /// The production manifest for the current macOS process architecture.
    ///
    /// Chrome for Testing publishes separate arm64 and x86_64 archives. The
    /// URLs are pinned to one revision; callers must not substitute a URL from
    /// page content or an untrusted configuration file.
    static let production = ChromiumRuntimeManifest(
        version: "152.0.7977.42",
        artifacts: [
            "arm64": ChromiumRuntimeArtifact(
                version: "152.0.7977.42",
                platform: "mac-arm64",
                downloadURL: URL(string: "https://storage.googleapis.com/chrome-for-testing-public/152.0.7977.42/mac-arm64/chrome-headless-shell-mac-arm64.zip")!,
                sha256: "4cca5044201c5472469d26bef44a24aa2ec2e0ce2d1ef4959b8dae3fa662cec1"
            ),
            "x86_64": ChromiumRuntimeArtifact(
                version: "152.0.7977.42",
                platform: "mac-x64",
                downloadURL: URL(string: "https://storage.googleapis.com/chrome-for-testing-public/152.0.7977.42/mac-x64/chrome-headless-shell-mac-x64.zip")!,
                sha256: "f5dc6fc2a0009b5503fffad9006d2dc7bfc6f0650c2cbbeb1b294676cf74a97a"
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
