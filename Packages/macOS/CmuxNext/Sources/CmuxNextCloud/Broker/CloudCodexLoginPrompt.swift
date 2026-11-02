public import Foundation

/// A device-code response for the one-time Codex sign-in. The code is safe to
/// show in cmux; no credential or auth cache is included.
nonisolated public struct CloudCodexLoginPrompt: Sendable, Equatable {
    public let verificationURL: URL
    public let userCode: String

    nonisolated public init(verificationURL: URL, userCode: String) {
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

