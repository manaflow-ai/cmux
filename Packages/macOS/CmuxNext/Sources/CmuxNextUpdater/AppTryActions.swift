public import AppKit
public import CmuxNextActions
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import os

/// Run a PR as This App… and Undo Last PR Run: the Command Palette face of `cmux app try
/// <PR|branch|sha>` and `cmux app try undo` (cmux-tui/crates/cmux-tui/src/cli/app/try_cmd.rs).
/// Leo (2026-11-14): "How deep and fast and ergonomic is hot swapping and can we push it further
/// and productionize it further". Rust picks the path (the commit's live binaries, else its nightly
/// build), checks it and writes the receipt that undo reads. These rows only run the bundled CLI off
/// the main actor and show a working toast, then the CLI's own localized line or error, the way
/// Edit cmux Live… does.
@MainActor
public enum AppTryActions {
    public static let runID: ActionID = "app.try.run"
    public static let undoID: ActionID = "app.try.undo"
    /// The run's argument, the PR number, branch or commit (the catalog's `target`).
    public static let targetName = "target"
    private static let toastID = "app-try"
    /// A live swap downloads and checks the commit's binaries; a full build installs and relaunches.
    static let runTimeout: Duration = .seconds(300)
    static let undoTimeout: Duration = .seconds(120)

    /// The CLI words for `id`: `app try <target>` and `app try undo`; nil for any other id, or a
    /// run with no target.
    public nonisolated static func arguments(for id: ActionID, target: String?) -> [String]? {
        if id == undoID { return ["app", "try", "undo"] }
        guard id == runID else { return nil }
        let trimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : ["app", "try", trimmed]
    }

    /// Binds both rows.
    ///
    /// - Parameters:
    ///   - registry: The app's action registry.
    ///   - cli: The bundled `cmux` CLI, or nil when this build carries none.
    ///   - window: The window the toasts show in.
    public static func bind(into registry: ActionRegistry, cli: @escaping @MainActor () -> URL?,
                            window: @escaping @MainActor () -> NSWindow?) {
        let noCLI: @MainActor () -> String? = { cli() == nil ? AppTryStrings.noCLI : nil }
        for id in [runID, undoID] {
            registry.bindEffect(id, unavailable: noCLI, effect: { [weak registry] invocation in
                guard let executable = cli() else { return .refused(AppTryStrings.noCLI) }
                guard let arguments = arguments(for: id, target: invocation[targetName]?.stringValue) else {
                    return .refused(AppTryStrings.targetRequired)
                }
                let title = registry?.descriptor(for: id)?.title ?? id.rawValue
                let shown = window()
                let undo = id == undoID
                let timeout = undo ? undoTimeout : runTimeout
                show(undo ? AppTryStrings.undoing : AppTryStrings.running(arguments[2]), in: shown, duration: timeout)
                return .applied(result: { await run(executable, arguments, timeout: timeout, title: title, in: shown) })
            })
        }
    }

    /// Runs `cmux <arguments>` and replaces the working toast with the CLI's own last line: the
    /// applied, undone or already-there line on success, its error otherwise.
    private static func run(_ cli: URL, _ arguments: [String], timeout: Duration, title: String,
                            in window: NSWindow?) async -> Result<[String: ActionResultValue], ActionWorkFailure> {
        let outcome = await runProcess(cli, arguments, timeout: timeout)
        guard let outcome, outcome.succeeded else {
            let why = outcome.map { lastLine($0.errorOutput) ?? lastLine($0.output) ?? "exit \($0.status)" } ?? AppTryStrings.didNotFinish
            let message = AppTryStrings.failed(title, why)
            show(message, in: window, duration: .seconds(12))
            var failure = ActionWorkFailure(message)
            failure.shown = true // the toast above already says it
            return .failure(failure)
        }
        show(lastLine(outcome.output) ?? title, in: window, duration: .seconds(8))
        return .success(["output": .string(outcome.text)])
    }

    @concurrent nonisolated private static func runProcess(_ cli: URL, _ arguments: [String], timeout: Duration) async -> ProcessOutcome? {
        try? await AsyncProcess().run(ProcessRequest(cli, arguments, errorOutput: .separate, timeout: timeout))
    }

    private nonisolated static func lastLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
    }

    private static func show(_ message: String, in window: NSWindow?, duration: Duration) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app-try").info("app try: \(message, privacy: .public)")
            return
        }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message, duration: duration), in: window)
    }
}

nonisolated enum AppTryStrings {
    static var noCLI: String { UpdaterStrings.text("updater.appTry.noCLI", "This build does not include the cmux CLI.") }
    static var targetRequired: String {
        UpdaterStrings.text("updater.appTry.targetRequired", "Pass a PR number, branch or commit as target.")
    }
    static var undoing: String { UpdaterStrings.text("updater.appTry.undoing", "Putting back what the last PR run replaced…") }
    static var didNotFinish: String { UpdaterStrings.text("updater.appTry.didNotFinish", "it did not finish in time") }
    static func running(_ target: String) -> String {
        UpdaterStrings.format("updater.appTry.running", "Getting %@ ready to run as this app…", target)
    }
    static func failed(_ title: String, _ why: String) -> String {
        UpdaterStrings.format("updater.appTry.failed", "%1$@: %2$@", title, why)
    }
}
