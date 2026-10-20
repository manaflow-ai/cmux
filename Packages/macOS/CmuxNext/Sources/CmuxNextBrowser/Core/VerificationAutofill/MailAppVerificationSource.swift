public import Foundation

/// Reads new messages from Mail.app. Stub: the red commit of its tests.
public nonisolated struct MailAppVerificationSource: VerificationEmailSource {
    public enum Failure: Error, Sendable, Hashable {
        case notAuthorized
        case scriptFailed(String)
        case unreadableOutput
    }
    public init(runner: any VerificationScriptRunning = OsascriptRunner()) {}
    public func emails(receivedSince since: Date) async throws -> [VerificationEmail] { [] }
}
