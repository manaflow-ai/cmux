import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextCLIInstall
import CmuxNextDaemon
import os

/// Install cmux CLI in PATH and Uninstall cmux CLI from PATH (the old app's
/// "Shell Command" palette rows), and the once-per-channel launch offer:
/// `CLIPathInstaller` runs off the main actor, since it may wait on the
/// administrator prompt, and the outcome shows as a toast on the active
/// window (`CLIInstallReport`).
enum CLIInstallHandlers {
    static let toastID = "cli-install"
    /// Set once the launch offer ran, so it shows once per app channel.
    static let offeredAtLaunchKey = "cli.install.offeredAtLaunch"

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
                    show(CLIInstallReport.uninstalled(outcome).message, in: window)
                } catch {
                    show(CLIInstallReport.failed(installing: false, error), in: window)
                }
            }
        })
    }

    /// Installs `name` where `CLIInstallPlan` puts it. When another app's CLI
    /// or a file is in the way and the caller did not pass `replace`, nothing
    /// is replaced: `cmux` goes in as `cmux-next` beside it, and the toast's
    /// Replace (a person's click) makes this app's CLI the `cmux` command. A
    /// link that an earlier PATH folder shadows is said too, with Replace for
    /// the one that runs instead.
    @MainActor static func install(_ name: CLIPathInstaller.Name, replacing: Bool, in window: NSWindow?) async {
        let source = CLIPathInstaller().source
        let check = await pathCheck(source)
        let plan = CLIInstallPlan(name: name, replacing: replacing, check: check)
        let replace = CmuxToast.Action(title: CLIInstallButton.replace.title)
        let replaceCmux: @MainActor () -> Void = { Task { @MainActor in await install(.cmux, replacing: true, in: window) } }
        do {
            let path = try await CLIPathInstaller(destination: plan.destination).install(replacing: plan.replaces).destination.path
            guard name == .cmux else { return show(CLIInstallReport.installed(path: path).message, in: window) }
            let after = await pathCheck(source)
            if after.runsThisApp {
                show((plan.repointedFrom.map { .repointed(path: path, from: $0) } ?? CLIInstallReport.installed(path: path)).message, in: window)
            } else if let entry = after.entry {
                show(CLIInstallReport.shadowed(path: path, entry: entry.path, classic: after.status.isClassic).message,
                     action: replace, in: window, run: replaceCmux)
            } else {
                show(CLIInstallReport.notOnPath(path: path).message, in: window)
            }
        } catch CLIPathInstaller.Failure.occupied(let path, _) where name == .cmux {
            do {
                let beside = try await CLIPathInstaller(destination: CLIPathInstaller.Name.cmuxNext.destination).install(replacing: false)
                let classic = check.entry?.path == path && check.status.isClassic
                show(CLIInstallReport.installedBeside(path: beside.destination.path, other: path, classic: classic).message,
                     action: replace, in: window, run: replaceCmux)
            } catch {
                show(CLIInstallReport.failed(installing: true, error), action: replace, in: window, run: replaceCmux)
            }
        } catch let failure as CLIPathInstaller.Failure {
            guard case .occupied = failure else { return show(CLIInstallReport.failed(installing: true, failure), in: window) }
            show(CLIInstallReport.failed(installing: true, failure), action: replace, in: window) {
                Task { @MainActor in await install(name, replacing: true, in: window) }
            }
        } catch {
            show(CLIInstallReport.failed(installing: true, error), in: window)
        }
    }

    /// Once per app channel, after the first-run steps: when `cmux` in a new
    /// shell would not run this app, a toast says so and offers to fix it
    /// (`CLIInstallReport.launchOffer`). Never for DEV builds, captures, or a
    /// copy running from its disk image (offered once it runs from
    /// Applications). Classic's link is named as classic's and replaced only
    /// on the person's click.
    @MainActor static func offerAtLaunch(skipsOnboarding: Bool, defaults: UserDefaults = .standard) async {
        guard !skipsOnboarding, !defaults.bool(forKey: offeredAtLaunchKey),
              Bundle.main.bundleIdentifier?.contains(".debug") != true else { return }
        let check = await pathCheck(CLIPathInstaller().source)
        guard !check.appRunsFromImage else { return }
        defaults.set(true, forKey: offeredAtLaunchKey)
        guard let offer = CLIInstallReport.launchOffer(check) else { return }
        show(offer.report.message, action: CmuxToast.Action(title: offer.button.title), in: nil) {
            Task { @MainActor in await install(.cmux, replacing: offer.replacing, in: nil) }
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
