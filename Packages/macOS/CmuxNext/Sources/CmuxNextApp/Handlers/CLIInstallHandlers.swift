import AppKit
import CmuxNextDesign
import CmuxNextActions

/// Install cmux CLI in PATH and Uninstall cmux CLI from PATH (the old app's
/// "Shell Command" palette rows): `CLIPathInstaller` runs off the main
/// actor, since it may wait on the administrator prompt, and the outcome
/// shows as a sheet on the active window.
enum CLIInstallHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.installCLI", run: { _ in
            let window = context.activeWindow?.window
            Task { // task-owner: one install, ended by its sheet
                do {
                    let outcome = try await CLIPathInstaller().install()
                    show(CLIInstallStrings.installed, CLIInstallStrings.body(outcome), in: window)
                } catch {
                    show(CLIInstallStrings.installFailed, CLIInstallStrings.message(error), in: window)
                }
            }
        })
        registry.bind("palette.uninstallCLI", run: { _ in
            let window = context.activeWindow?.window
            Task { // task-owner: one uninstall, ended by its sheet
                do {
                    let outcome = try await CLIPathInstaller().uninstall()
                    show(CLIInstallStrings.uninstalled, CLIInstallStrings.body(outcome), in: window)
                } catch {
                    show(CLIInstallStrings.uninstallFailed, CLIInstallStrings.message(error), in: window)
                }
            }
        })
    }

    /// A cmux dialog on the window, else app-wide (never an app-modal run loop).
    private static func show(_ title: String, _ body: String, in window: NSWindow?) {
        let spec = CmuxDialogSpec(title: title, lines: [body], buttons: [.ok(CLIInstallStrings.ok)], identifier: "cmux.dialog.cliInstall")
        let scope: CmuxDialogScope = (window ?? NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app
        CmuxDialogCenter.shared.present(spec, in: scope) { _ in }
    }
}

enum CLIInstallStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CLIInstall", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    static var installed: String { text("cli.installed", "cmux CLI Installed") }
    static var installFailed: String { text("cli.installFailed", "Couldn't Install cmux CLI") }
    static var uninstalled: String { text("cli.uninstalled", "cmux CLI Uninstalled") }
    static var uninstallFailed: String { text("cli.uninstallFailed", "Couldn't Uninstall cmux CLI") }
    static var ok: String { text("common.ok", "OK") }

    static func body(_ outcome: CLIPathInstaller.InstallOutcome) -> String {
        let created = format("cli.install.symlinkCreated", "Created symlink:\n\n%1$@ -> %2$@",
                             outcome.destination.path, outcome.source.path)
        var body = created
        if outcome.usedAdministratorPrivileges {
            body += "\n\n" + text("cli.install.adminRequired", "Administrator privileges were required to write to /usr/local/bin.")
        }
        switch outcome.replaced {
        case .link(let target):
            body += "\n\n" + format("cli.install.replacedLink", "It replaced the previous link to %@.", target)
        case .file:
            body += "\n\n" + format("cli.install.replacedFile", "It replaced the file that was at %@.", outcome.destination.path)
        case nil:
            break
        }
        return body
    }

    static func body(_ outcome: CLIPathInstaller.UninstallOutcome) -> String {
        let path = outcome.destination.path
        let result = outcome.removedExistingEntry
            ? format("cli.uninstall.removed", "Removed %@.", path)
            : format("cli.uninstall.notFound", "No cmux CLI symlink was found at %@.", path)
        guard outcome.usedAdministratorPrivileges else { return result }
        return result + "\n\n" + text("cli.uninstall.adminRequired", "Administrator privileges were required to modify /usr/local/bin.")
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
        }
    }
}
