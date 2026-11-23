public import AppKit
public import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import os

/// One palette row's run of the bundled cmux CLI, told in one toast that its outcome replaces
/// (Run a PR as This App…, Edit cmux Live…): the command's error, or `done`, or the command's own
/// last line.
@MainActor
public struct CLIRowToast: Sendable {
    private let id: String
    private let category: String
    private let didNotFinish: @MainActor @Sendable () -> String
    private let failed: @MainActor @Sendable (String) -> String

    /// - Parameters:
    ///   - id: The toast's id, so each message replaces the last.
    ///   - category: The log category a message with no window goes to.
    ///   - didNotFinish: Why, when the command ran past its timeout.
    ///   - failed: The failure message around the command's reason.
    public init(id: String, category: String, didNotFinish: @escaping @MainActor @Sendable () -> String,
                failed: @escaping @MainActor @Sendable (String) -> String) {
        self.id = id
        self.category = category
        self.didNotFinish = didNotFinish
        self.failed = failed
    }

    /// Runs `cmux <arguments>` and shows how it went; `done` nil shows the command's last line.
    public func run(_ cli: URL, _ arguments: [String], timeout: Duration, done: String?,
                    in window: NSWindow?) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let result = await BundledCLIRun.run(cli, arguments, timeout: timeout)
        guard let result, result.status == 0 else {
            let why = result.map { BundledCLIRun.lastLine($0.stderr) ?? BundledCLIRun.lastLine($0.stdout) ?? "exit \($0.status)" } ?? didNotFinish()
            let message = failed(why)
            show(message, in: window, duration: .seconds(12))
            var failure = ActionWorkFailure(message)
            failure.shown = true // the toast above already says it
            return .failure(failure)
        }
        if let line = done ?? BundledCLIRun.lastLine(result.stdout) { show(line, in: window, duration: .seconds(8)) }
        return .success(["output": .string(String(decoding: result.stdout, as: UTF8.self))])
    }

    public func show(_ message: String, in window: NSWindow?, duration: Duration) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            Logger(subsystem: "com.cmuxterm.app.next", category: category).info("\(category, privacy: .public): \(message, privacy: .public)")
            return
        }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, duration: duration), in: window)
    }
}
