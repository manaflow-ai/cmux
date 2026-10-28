import CmuxNextWakeups
public import Foundation

/// Runs `/usr/bin/osascript` with arguments and returns its standard output: the seam that
/// ``MailAppVerificationSource`` reads Mail through, so tests pass a fake.
public protocol VerificationScriptRunning: Sendable {
    /// - Parameter arguments: The `osascript` arguments.
    /// - Returns: Standard output.
    /// - Throws: ``VerificationScriptFailure`` on a non-zero exit.
    func run(_ arguments: [String]) async throws -> String
}

/// `osascript` exited non-zero.
public nonisolated struct VerificationScriptFailure: Error, Sendable, Hashable {
    public let status: Int32
    /// Standard error, trimmed.
    public let message: String

    public init(status: Int32, message: String) {
        self.status = status
        self.message = message
    }
}

/// The real runner: one `osascript` process per call through ``AsyncProcess``, which spawns it off
/// the caller at the caller's priority and reads both pipes without holding a thread. A cancelled
/// caller stops the script: nobody wants the read any more.
public nonisolated struct OsascriptRunner: VerificationScriptRunning {
    /// Called with osascript's pid on the thread that spawned it (tests check that thread).
    private let onLaunch: (@Sendable (Int32) -> Void)?

    public init() {
        self.init(onLaunch: nil)
    }

    /// Creates a runner that reports each spawn to `onLaunch` (tests).
    init(onLaunch: (@Sendable (Int32) -> Void)?) {
        self.onLaunch = onLaunch
    }

    @concurrent public func run(_ arguments: [String]) async throws -> String {
        let outcome = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/osascript"), arguments,
                                                                  errorOutput: .separate, onLaunch: onLaunch))
        guard outcome.succeeded else {
            throw VerificationScriptFailure(status: outcome.status,
                                            message: String(decoding: outcome.errorOutput, as: UTF8.self)
                                                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outcome.text
    }
}
