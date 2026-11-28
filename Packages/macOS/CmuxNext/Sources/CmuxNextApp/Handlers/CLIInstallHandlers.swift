import AppKit
import CmuxNextDesign
import CmuxNextActions

/// Install cmux CLI in PATH and Uninstall cmux CLI from PATH (the old app's
/// "Shell Command" palette rows): `CLIPathInstaller` runs off the main
/// actor, since it may wait on the administrator prompt, and the outcome
/// shows as a sheet on the active window.
enum CLIInstallHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.installCLI", run: { invocation in
            let window = context.activeWindow?.window
            let name: CLIPathInstaller.Name = invocation["cmux_next"]?.boolValue == true ? .cmuxNext : .cmux
            let replacing = invocation["replace"]?.boolValue == true
            Task { @MainActor in // task-owner: one install, ended by its sheet
                await install(name, replacing: replacing, in: window)
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

    /// Installs `name`. When another app's CLI or a file is in the way and
    /// the caller did not pass `replace`, asks: replace it, install as
    /// `cmux-next` beside it, or cancel. Nothing is replaced without that
    /// explicit choice.
    @MainActor private static func install(_ name: CLIPathInstaller.Name, replacing: Bool, in window: NSWindow?) async {
        do {
            let outcome = try await CLIPathInstaller(destination: name.destination).install(replacing: replacing)
            show(CLIInstallStrings.installed, CLIInstallStrings.body(outcome), in: window)
        } catch let failure as CLIPathInstaller.Failure {
            guard case .occupied = failure else {
                show(CLIInstallStrings.installFailed, CLIInstallStrings.message(failure), in: window)
                return
            }
            var buttons: [CmuxDialogButton] = [.cancel(CLIInstallStrings.cancel),
                                               CmuxDialogButton(id: "replace", title: CLIInstallStrings.replace, role: .destructive)]
            if name != .cmuxNext {
                buttons.append(CmuxDialogButton(id: "cmux-next", title: CLIInstallStrings.installAsCmuxNext, role: .default))
            }
            let spec = CmuxDialogSpec(title: CLIInstallStrings.occupiedTitle, lines: [CLIInstallStrings.message(failure)],
                                      buttons: buttons, identifier: "cmux.dialog.cliInstall.occupied")
            switch await CmuxDialogCenter.shared.present(spec, in: scope(window)).button {
            case "replace": await install(name, replacing: true, in: window)
            case "cmux-next": await install(.cmuxNext, replacing: false, in: window)
            default: break
            }
        } catch {
            show(CLIInstallStrings.installFailed, CLIInstallStrings.message(error), in: window)
        }
    }

    private static func scope(_ window: NSWindow?) -> CmuxDialogScope {
        (window ?? NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app
    }

    /// A cmux dialog on the window, else app-wide (never an app-modal run loop).
    private static func show(_ title: String, _ body: String, in window: NSWindow?) {
        let spec = CmuxDialogSpec(title: title, lines: [body], buttons: [.ok(CLIInstallStrings.ok)], identifier: "cmux.dialog.cliInstall")
        CmuxDialogCenter.shared.present(spec, in: scope(window)) { _ in }
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
    static var cancel: String { text("common.cancel", "Cancel") }
    static var replace: String { text("cli.button.replace", "Replace") }
    static var installAsCmuxNext: String { text("cli.button.installAsCmuxNext", "Install as cmux-next") }
    static var occupiedTitle: String { text("cli.occupied.title", "Another cmux CLI Is Installed") }

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
