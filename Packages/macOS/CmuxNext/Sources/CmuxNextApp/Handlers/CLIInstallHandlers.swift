import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextCLIInstall
import CmuxNextDaemon
import os

/// Install cmux CLI in PATH and Uninstall cmux CLI from PATH (the old app's
/// "Shell Command" palette rows): `CLIPathInstaller` runs off the main
/// actor, since it may wait on the administrator prompt, and the outcome
/// shows as a toast on the active window (Lawrence 2026-10-07: results are
/// toasts, never dialogs).
enum CLIInstallHandlers {
    static let toastID = "cli-install"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.installCLI", run: { invocation in
            let window = context.activeWindow?.window
            let name: CLIPathInstaller.Name = invocation["cmuxNext"]?.boolValue == true ? .cmuxNext : .cmux
            let replacing = invocation["replace"]?.boolValue == true
            Task { @MainActor in // task-owner: one install, ended by its toast
                await install(name, replacing: replacing, in: window)
            }
        })
        registry.bind("palette.uninstallCLI", run: { _ in
            let window = context.activeWindow?.window
            Task { // task-owner: one uninstall, ended by its toast
                do {
                    let outcome = try await CLIPathInstaller().uninstall()
                    show(CLIInstallStrings.body(outcome), in: window)
                } catch {
                    show(CLIInstallStrings.failed(CLIInstallStrings.uninstallFailed, error), in: window)
                }
            }
        })
    }

    /// Installs `name`. `cmux` goes where a shell finds it (``CLIPathCheck``):
    /// a link into a deleted cmux app is repointed and said; when another
    /// app's CLI or a file is in the way and the caller did not pass
    /// `replace`, nothing is replaced: `cmux` goes in as `cmux-next` beside
    /// it, and the toast's Replace (a person's click) makes this app's CLI the
    /// `cmux` command. A link that an earlier PATH folder shadows is said too,
    /// with Replace for the one that runs instead.
    @MainActor static func install(_ name: CLIPathInstaller.Name, replacing: Bool, in window: NSWindow?) async {
        let source = CLIPathInstaller().source
        let check = await pathCheck(source)
        var destination = name.destination
        var repointed: String?
        if name == .cmux {
            destination = replacing ? check.replaceDestination : check.installDestination
            if case .dangling(let target) = check.status, destination == check.entry { repointed = target }
        }
        let replace = CmuxToast.Action(title: CLIInstallStrings.replace)
        let replaceRun: @MainActor () -> Void = { Task { @MainActor in await install(.cmux, replacing: true, in: window) } }
        do {
            // A link into a cmux app that is gone runs nothing: repointing it replaces no one's CLI.
            let outcome = try await CLIPathInstaller(destination: destination).install(replacing: replacing || repointed != nil)
            let path = outcome.destination.path
            guard name == .cmux else { return show(CLIInstallStrings.installed(at: path), in: window) }
            let after = await pathCheck(source)
            if after.runsThisApp {
                show(repointed.map { CLIInstallStrings.repointed(path, from: $0) } ?? CLIInstallStrings.installed(at: path), in: window)
            } else if let entry = after.entry {
                show(CLIInstallStrings.shadowed(path, by: entry.path, after.status), action: replace, in: window, run: replaceRun)
            } else {
                show(CLIInstallStrings.notOnPath(path), in: window)
            }
        } catch let failure as CLIPathInstaller.Failure {
            guard case .occupied(let path, _) = failure else {
                show(CLIInstallStrings.failed(CLIInstallStrings.installFailed, failure), in: window)
                return
            }
            guard name != .cmuxNext else {
                show(CLIInstallStrings.failed(CLIInstallStrings.installFailed, failure), action: replace, in: window) {
                    Task { @MainActor in await install(name, replacing: true, in: window) }
                }
                return
            }
            let classic = check.entry?.path == path && check.status.isClassic
            do {
                let beside = try await CLIPathInstaller(destination: CLIPathInstaller.Name.cmuxNext.destination).install(replacing: false)
                show(CLIInstallStrings.installedBeside(beside.destination.path, other: path, classic: classic), action: replace, in: window, run: replaceRun)
            } catch {
                show(CLIInstallStrings.failed(CLIInstallStrings.installFailed, error), action: replace, in: window, run: replaceRun)
            }
        } catch {
            show(CLIInstallStrings.failed(CLIInstallStrings.installFailed, error), in: window)
        }
    }

    /// Set once the launch offer ran, so it shows once per app channel.
    static let offeredAtLaunchKey = "cli.install.offeredAtLaunch"

    /// Once per app channel, after the first-run steps: when `cmux` in a new
    /// shell would not run this app (missing, a link into a deleted app,
    /// another cmux app's CLI), a toast says so and offers to fix it. Never
    /// for DEV builds, captures, or a copy running from its disk image; a
    /// CLI that is not in any app (a build of it) is left alone. Classic's
    /// link is named as classic's and replaced only on the person's click.
    @MainActor static func offerAtLaunch(skipsOnboarding: Bool, defaults: UserDefaults = .standard) async {
        guard !skipsOnboarding, !defaults.bool(forKey: offeredAtLaunchKey),
              Bundle.main.bundleIdentifier?.contains(".debug") != true else { return }
        let check = await pathCheck(CLIPathInstaller().source)
        // Offered once it runs from Applications, not from the image.
        guard !check.appRunsFromImage else { return }
        defaults.set(true, forKey: offeredAtLaunchKey)
        let message: String
        let action: String
        let replacing: Bool
        switch check.status {
        case .thisApp, .foreign:
            return
        case .missing:
            (message, action, replacing) = (CLIInstallStrings.offerMissing, CLIInstallStrings.install, false)
        case .dangling(let target):
            (message, action, replacing) = (CLIInstallStrings.offerDangling(check.entry?.path ?? "", target: target), CLIInstallStrings.repoint, false)
        case .otherApp(let bundle, let classic):
            (message, action, replacing) = (CLIInstallStrings.offerOther(check.entry?.path ?? "", bundle: bundle, classic: classic), CLIInstallStrings.replace, true)
        }
        show(message, action: CmuxToast.Action(title: action), in: nil) {
            Task { @MainActor in await install(.cmux, replacing: replacing, in: nil) }
        }
    }

    /// The `cmux` a new login shell runs, from the login `PATH` the app last captured.
    private static func pathCheck(_ source: URL) async -> CLIPathCheck {
        await CLIPathCheck.current(path: LoginEnvironment.shared.rememberedPath(), source: source)
    }

    /// A toast on the window (else the key or main window); a long one with
    /// an action stays 12 s.
    @MainActor private static func show(_ message: String, action: CmuxToast.Action? = nil, in window: NSWindow?,
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
    static var install: String { text("cli.button.install", "Install") }
    static var repoint: String { text("cli.button.repoint", "Repoint") }

    static func installed(at path: String) -> String { format("cli.toast.installed", "cmux CLI installed at %@", path) }

    /// `cmux` was taken: this app's CLI went in as `path` beside the other one.
    static func installedBeside(_ path: String, other: String, classic: Bool) -> String {
        classic
            ? format("cli.toast.installedBesideClassic", "Installed as %1$@. cmux classic's CLI stays at %2$@, so `cmux` still runs classic.", path, other)
            : format("cli.toast.installedBeside", "Installed as %1$@. Another app's cmux CLI stays at %2$@.", path, other)
    }

    /// A link into a deleted cmux app (`target`) now points at this app.
    static func repointed(_ path: String, from target: String) -> String {
        format("cli.toast.repointed", "cmux CLI installed at %1$@. It linked to an app that is gone (%2$@).", path, target)
    }

    /// Installed at `path`, but `entry`, earlier on PATH, is what `cmux` runs.
    static func shadowed(_ path: String, by entry: String, _ status: CLIPathCheck.Status) -> String {
        status.isClassic
            ? format("cli.toast.shadowedClassic", "Installed at %1$@, but %2$@ comes first on PATH, so `cmux` still runs cmux classic.", path, entry)
            : format("cli.toast.shadowed", "Installed at %1$@, but %2$@ comes first on PATH, so `cmux` runs that one.", path, entry)
    }

    /// Installed at `path`, whose folder is not on the login PATH.
    static func notOnPath(_ path: String) -> String {
        format("cli.toast.notOnPath", "Installed at %@, but its folder is not on your shell's PATH.", path)
    }

    static var offerMissing: String {
        text("cli.offer.missing", "No `cmux` command in Terminal. Install the cmux CLI in PATH?")
    }

    static func offerDangling(_ entry: String, target: String) -> String {
        format("cli.offer.dangling", "`cmux` at %1$@ links to an app that is gone (%2$@). Point it at this app?", entry, target)
    }

    static func offerOther(_ entry: String, bundle: String, classic: Bool) -> String {
        classic
            ? format("cli.offer.classic", "`cmux` in Terminal runs cmux classic (%1$@). Replace makes it run this app; classic stays installed.", entry)
            : format("cli.offer.otherApp", "`cmux` in Terminal runs another cmux app (%1$@, from %2$@). Make it run this app?", entry, bundle)
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
        case .bundleNotInstalled(let path):
            return format("cli.error.bundleNotInstalled", "cmux is running from its disk image (%@). Move it to Applications, open it from there, and try again.", path)
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
