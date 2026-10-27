import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextCLIInstall
import CmuxNextWakeups
import os

/// Install cmux CLI in PATH and Uninstall cmux CLI from PATH (the old app's
/// "Shell Command" palette rows): `CLIPathInstaller` runs off the main
/// actor, since it may wait on the administrator prompt, and the outcome
/// shows as a toast on the active window, posted as userBlocking work: the
/// rest of the person's action (p06 rule 2; Lawrence 2026-10-07: results are
/// toasts, never dialogs).
enum CLIInstallHandlers {
    static let toastID = "cli-install"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.installCLI", run: { invocation in
            let window = context.activeWindow?.window
            let name: CLIPathInstaller.Name = invocation["cmux_next"]?.boolValue == true ? .cmuxNext : .cmux
            install(name, replacing: invocation["replace"]?.boolValue == true, in: window, services: context.services)
        })
        registry.bind("palette.uninstallCLI", run: { _ in
            let window = context.activeWindow?.window, mainWork = context.services.mainWork
            // task-owner: one uninstall off the main actor, ended by its toast
            context.services.work.task(.userBlocking) {
                let outcome = await uninstall()
                mainWork.postFromAnyThread(.userBlocking, owner: "cli-install.toast") { show(outcome, in: window) }
            }
        })
    }

    /// What an install or uninstall ended with: found off the main actor, shown on it.
    private nonisolated enum Outcome: Sendable {
        case installed(path: String)
        /// `cmux` was taken: this app's CLI went in as `path` beside the CLI at `other`.
        case installedBeside(path: String, other: String)
        case uninstalled(CLIPathInstaller.UninstallOutcome)
        /// An install (else an uninstall) failed; `offersReplace` when something else holds the path.
        case failed(installing: Bool, error: any Error, offersReplace: Bool)
    }

    /// Installs `name` off the main actor and shows the outcome. When another app's CLI or a
    /// file is in the way and the caller did not pass `replace`, nothing is replaced: `cmux`
    /// goes in as `cmux-next` beside it, and the toast's Replace (a person's click) makes this
    /// app's CLI the `cmux` command.
    private static func install(_ name: CLIPathInstaller.Name, replacing: Bool, in window: NSWindow?, services: AppServices) {
        let mainWork = services.mainWork
        // task-owner: one install off the main actor, ended by its toast
        services.work.task(.userBlocking) {
            let outcome = await attempt(name, replacing: replacing)
            mainWork.postFromAnyThread(.userBlocking, owner: "cli-install.toast") {
                show(outcome, in: window) { install(name, replacing: true, in: window, services: services) }
            }
        }
    }

    private nonisolated static func attempt(_ name: CLIPathInstaller.Name, replacing: Bool) async -> Outcome {
        do {
            let outcome = try await CLIPathInstaller(destination: name.destination).install(replacing: replacing)
            return .installed(path: outcome.destination.path)
        } catch let failure as CLIPathInstaller.Failure {
            guard case .occupied(let path, _) = failure else { return .failed(installing: true, error: failure, offersReplace: false) }
            guard name != .cmuxNext else { return .failed(installing: true, error: failure, offersReplace: true) }
            do {
                let beside = try await CLIPathInstaller(destination: CLIPathInstaller.Name.cmuxNext.destination).install(replacing: false)
                return .installedBeside(path: beside.destination.path, other: path)
            } catch {
                return .failed(installing: true, error: error, offersReplace: true)
            }
        } catch {
            return .failed(installing: true, error: error, offersReplace: false)
        }
    }

    private nonisolated static func uninstall() async -> Outcome {
        do {
            return .uninstalled(try await CLIPathInstaller().uninstall())
        } catch {
            return .failed(installing: false, error: error, offersReplace: false)
        }
    }

    /// The outcome's toast; its Replace runs `replace`.
    private static func show(_ outcome: Outcome, in window: NSWindow?, replace: (@MainActor () -> Void)? = nil) {
        let action = CmuxToast.Action(title: CLIInstallStrings.replace)
        switch outcome {
        case .installed(let path):
            show(CLIInstallStrings.installed(at: path), in: window)
        case .installedBeside(let path, let other):
            show(CLIInstallStrings.installedBeside(path, other: other), action: action, in: window, run: replace)
        case .uninstalled(let result):
            show(CLIInstallStrings.body(result), in: window)
        case .failed(let installing, let error, let offersReplace):
            let message = CLIInstallStrings.failed(installing ? CLIInstallStrings.installFailed : CLIInstallStrings.uninstallFailed, error)
            show(message, action: offersReplace ? action : nil, in: window, run: offersReplace ? replace : nil)
        }
    }

    /// A toast on the window (else the key or main window); a long one with
    /// an action stays 12 s.
    private static func show(_ message: String, action: CmuxToast.Action? = nil, in window: NSWindow?,
                             run: (@MainActor () -> Void)? = nil) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "cli.install").info("cli install result with no window: \(message, privacy: .public)")
            return
        }
        let toast = CmuxToast(id: toastID, message: message, action: action, duration: .seconds(action == nil ? 6 : 12))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = run
    }
}

enum CLIInstallStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CLIInstall", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    static var installFailed: String { text("cli.installFailed", "Couldn't Install cmux CLI") }
    static var uninstallFailed: String { text("cli.uninstallFailed", "Couldn't Uninstall cmux CLI") }
    static var replace: String { text("cli.button.replace", "Replace") }

    static func installed(at path: String) -> String { format("cli.toast.installed", "cmux CLI installed at %@", path) }

    /// `cmux` was taken: this app's CLI went in as `path` beside the other one.
    static func installedBeside(_ path: String, other: String) -> String {
        format("cli.toast.installedBeside", "Installed as %1$@. Another app's cmux CLI stays at %2$@.", path, other)
    }

    /// "Couldn't Install cmux CLI: <why>".
    static func failed(_ title: String, _ error: any Error) -> String {
        format("cli.toast.failed", "%1$@: %2$@", title, message(error))
    }

    static func body(_ outcome: CLIPathInstaller.UninstallOutcome) -> String {
        let path = outcome.destination.path
        return outcome.removedExistingEntry
            ? format("cli.uninstall.removed", "Removed %@.", path)
            : format("cli.uninstall.notFound", "No cmux CLI symlink was found at %@.", path)
    }

    static func message(_ error: any Error) -> String {
        guard let failure = error as? CLIPathInstaller.Failure else { return error.localizedDescription }
        switch failure {
        case .bundledCLIMissing(let path):
            return format("cli.error.bundledCLIMissing", "The bundled cmux CLI was not found at %@.", path)
        case .destinationParentNotDirectory(let path):
            return format("cli.error.parentNotDirectory", "%@ is not a folder.", path)
        case .destinationIsDirectory(let path):
            return format("cli.error.destinationIsDirectory", "%@ is a folder. Remove or rename it and try again.", path)
        case .installVerificationFailed(let path):
            return format("cli.error.installVerificationFailed", "The symlink at %@ does not point to the bundled cmux CLI.", path)
        case .uninstallVerificationFailed(let path):
            return format("cli.error.uninstallVerificationFailed", "Couldn’t remove %@.", path)
        case .privilegedCommandFailed(let message):
            return format("cli.error.privilegedCommandFailed", "Administrator action failed: %@", message)
        case .occupied(let path, .link(let target)):
            return format("cli.error.occupiedLink", "%1$@ links to another app's CLI (%2$@), so it was left alone.", path, target)
                + " " + choices
        case .occupied(let path, .file):
            return format("cli.error.occupiedFile", "%@ is a file this app did not install, so it was left alone.", path) + " " + choices
        }
    }

    /// How to choose after a refusal: replace explicitly, or the name that
    /// never shadows.
    private static var choices: String {
        format("cli.error.occupiedChoices",
               "To make this app's CLI the cmux command, choose Replace or run `cmux settings install-cli-in-path --replace`. To keep both, install it as %@, which never shadows the other one.",
               CLIPathInstaller.Name.cmuxNext.destination.path)
    }
}
