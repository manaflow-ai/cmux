import Foundation

/// The page side of email verification AutoFill. Stub: the red commit of its tests.
nonisolated struct VerificationPageScripts {
    static let channel = "cmuxVerify"
    static let world = "cmux-verify"
    static func detectorScript(post: String, ready: String = "true") -> String { "" }
    static func isWaitingReport(_ body: Any) -> Bool { false }
    static func fillScript(code: String) -> String { "false" }
}
