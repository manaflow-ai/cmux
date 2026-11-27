public import AppKit
public import CmuxNextActions
public import CmuxNextDaemon
import Foundation

/// Run a PR as This App… and Undo Last PR Run (step B of #43637): the palette face of
/// `cmux app try <PR|branch|sha>` and `cmux app try undo`, the Rust command in cmux-tui `cli/app`
/// that picks the cheapest way to this app at the commit (live binaries, else the commit's build
/// from the nightly feed, installed as `cmux nightly install` does) and writes the receipt undo
/// reads. The app only asks for the target and runs the bundled CLI against its own bundle, so any
/// NIGHTLY does it, with no checkout. Leo (2026-11-14): "How deep and fast and ergonomic is hot
/// swapping and can we push it further and productionize it further".
@MainActor
public struct AppTryActions {
    public init() {}
    public static let runID: ActionID = "app.try.run"
    public static let undoID: ActionID = "app.try.undo"
    private static let toast = CLIRowToast(id: "app-try", category: "app-try", didNotFinish: { AppTryStrings.didNotFinish },
                                           failed: { AppTryStrings.failed($0) })
    /// A full-app path downloads and installs a whole build before the app restarts into it.
    private static let runTimeout: Duration = .seconds(900)
    private static let undoTimeout: Duration = .seconds(600)

    /// Binds both rows.
    /// - Parameters:
    ///   - bundled: The cmux CLI inside this app's bundle.
    ///   - app: This app's bundle path, which the run swaps.
    ///   - window: The window the progress toasts go to.
    public static func bind(into registry: ActionRegistry, bundled: BundledExecutable, app: String = Bundle.main.bundlePath,
                            window: @escaping @MainActor () -> NSWindow?) {
        Task { _ = await bundled.resolve() } // task-owner: none; one bounded file read whose answer bundled keeps
        let noCLI: @MainActor () -> String? = { bundled.known == nil ? AppTryStrings.noCLI : nil }
        registry.bindEffect(runID, unavailable: noCLI, effect: { invocation in
            guard let cli = bundled.known else { return .refused(AppTryStrings.noCLI) }
            let target = invocation["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty else {
                guard !registry.isCapturingRefusal else { return .refused(AppTryStrings.targetRequired) }
                // The target as a Cmd-Shift-P step; Return runs this again with it.
                registry.ask(runID, invocation, ActionArgumentAsk(argument: "target"))
                return .done
            }
            guard let arguments = runArguments(target: target, app: app) else {
                return .refused(AppTryStrings.targetRequired)
            }
            let window = window()
            toast.show(AppTryStrings.running(target), in: window, duration: runTimeout)
            return .applied(result: { await toast.run(cli, arguments, timeout: runTimeout, done: nil, in: window) })
        })
        registry.bindEffect(undoID, unavailable: noCLI, effect: { _ in
            guard let cli = bundled.known else { return .refused(AppTryStrings.noCLI) }
            let window = window()
            toast.show(AppTryStrings.undoing, in: window, duration: undoTimeout)
            return .applied(result: { await toast.run(cli, ["app", "try", "undo"], timeout: undoTimeout, done: nil, in: window) })
        })
    }

    /// `cmux app try TARGET --app APP`, nil for a target the CLI would read as a flag. The app is
    /// named so the run swaps this bundle, never another cmux the CLI might find first.
    public nonisolated static func runArguments(target: String, app: String) -> [String]? {
        guard !target.hasPrefix("-") else { return nil }
        return ["app", "try", target, "--app", app]
    }
}

enum AppTryStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AppTry", bundle: .localizedModule)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    static var noCLI: String { text("appTry.noCLI", "This build does not include the cmux CLI.") }
    static var didNotFinish: String { text("appTry.didNotFinish", "it did not finish in time") }
    static var targetRequired: String { text("appTry.targetRequired", "Pass the pull request, branch or commit to run as target.") }
    static var undoing: String { text("appTry.undoing", "Putting back what the last PR run replaced…") }
    static func running(_ target: String) -> String { format("appTry.running", "Running %@ as this app…", target) }
    static func failed(_ why: String) -> String { format("appTry.failed", "PR run: %@", why) }
}
