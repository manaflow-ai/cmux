import Foundation

/// A pinned download descriptor for the optional Chromium runtime.
///
/// No binary is stored in the repository; the descriptor is resolved and
/// downloaded only after a user opts into Chromium.
struct ChromiumRuntimeArtifact: Codable, Equatable, Sendable {
    let version: String
    let platform: String
    let downloadURL: URL
    let sha256: String?

    init(version: String, platform: String, downloadURL: URL, sha256: String? = nil) {
        self.version = version
        self.platform = platform
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}
