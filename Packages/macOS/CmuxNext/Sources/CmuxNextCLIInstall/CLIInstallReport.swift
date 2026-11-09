public import Foundation

/// Where an install of `name` goes, read from ``CLIPathCheck``: `cmux` goes
/// where a shell finds it, and a link into a deleted cmux app is repointed in
/// place (it runs nothing, so repointing it replaces no one's CLI).
public nonisolated struct CLIInstallPlan: Equatable, Sendable {
    public let destination: URL
    /// The dangling link's old target, when this plan repoints it.
    public let repointedFrom: String?
    /// Whether the install may replace what is at `destination`.
    public let replaces: Bool

    public init(name: CLIPathInstaller.Name, replacing: Bool, check: CLIPathCheck) {
        guard name == .cmux else {
            (destination, repointedFrom, replaces) = (name.destination, nil, replacing)
            return
        }
        destination = replacing ? check.replaceDestination : check.installDestination
        if case .dangling(let target) = check.status, destination == check.entry {
            repointedFrom = target
        } else {
            repointedFrom = nil
        }
        replaces = replacing || repointedFrom != nil
    }
}

/// The toast's buttons.
public nonisolated enum CLIInstallButton: Equatable, Sendable {
    case install, repoint, replace

    public var title: String {
        switch self {
        case .install: CLIInstallReport.text("cli.button.install", "Install")
        case .repoint: CLIInstallReport.text("cli.button.repoint", "Repoint")
        case .replace: CLIInstallReport.text("cli.button.replace", "Replace")
        }
    }
}

/// What a CLI install, uninstall or the launch offer tells the person, as a
/// toast (Lawrence 2026-10-07: results are toasts, never dialogs).
public nonisolated enum CLIInstallReport: Equatable, Sendable {
    case installed(path: String)
    /// `cmux` was taken: this app's CLI went in as `path` beside `other`.
    case installedBeside(path: String, other: String, classic: Bool)
    /// A link into a deleted cmux app (`from`) now points at this app.
    case repointed(path: String, from: String)
    /// Installed at `path`, but `entry`, earlier on PATH, is what `cmux` runs.
    case shadowed(path: String, entry: String, classic: Bool)
    /// Installed at `path`, whose folder is not on the login PATH.
    case notOnPath(path: String)
    /// Each link Uninstall looked at (``CLIPathCheck/uninstallDestinations``).
    case uninstalled([CLIPathInstaller.UninstallOutcome])
    /// At launch: no `cmux` on PATH.
    case offerMissing
    /// At launch: `entry` links to `target`, an app that is gone.
    case offerDangling(entry: String, target: String)
    /// At launch: `entry` runs another cmux app's CLI, from `bundle`.
    case offerOther(entry: String, bundle: String, classic: Bool)

    /// The launch offer for `check`, with its button and whether that button
    /// replaces; nil when `cmux` already runs this app or is not a cmux app's
    /// CLI (a build of it, left alone), or while this app runs from its disk
    /// image (offered once it runs from Applications).
    public static func launchOffer(_ check: CLIPathCheck) -> (report: CLIInstallReport, button: CLIInstallButton, replacing: Bool)? {
        guard !check.appRunsFromImage else { return nil }
        let entry = check.entry?.path ?? ""
        switch check.status {
        case .thisApp, .foreign: return nil
        case .missing: return (.offerMissing, .install, false)
        case .dangling(let target): return (.offerDangling(entry: entry, target: target), .repoint, false)
        case .otherApp(let bundle, let classic) where !check.entryIsInsideApp:
            return (.offerOther(entry: entry, bundle: bundle, classic: classic), .replace, true)
        // A CLI inside another app's bundle on PATH is never replaced, so there is nothing to offer.
        case .otherApp: return nil
        }
    }

    public var message: String {
        switch self {
        case .installed(let path):
            Self.format("cli.toast.installed", "cmux CLI installed at %@", path)
        case .installedBeside(let path, let other, true):
            Self.format("cli.toast.installedBesideClassic", "Installed as %1$@. cmux classic's CLI stays at %2$@, so `cmux` still runs classic.", path, other)
        case .installedBeside(let path, let other, false):
            Self.format("cli.toast.installedBeside", "Installed as %1$@. Another app's cmux CLI stays at %2$@.", path, other)
        case .repointed(let path, let from):
            Self.format("cli.toast.repointed", "cmux CLI installed at %1$@. It linked to an app that is gone (%2$@).", path, from)
        case .shadowed(let path, let entry, true):
            Self.format("cli.toast.shadowedClassic", "Installed at %1$@, but %2$@ comes first on PATH, so `cmux` still runs cmux classic.", path, entry)
        case .shadowed(let path, let entry, false):
            Self.format("cli.toast.shadowed", "Installed at %1$@, but %2$@ comes first on PATH, so `cmux` runs that one.", path, entry)
        case .notOnPath(let path):
            Self.format("cli.toast.notOnPath", "Installed at %@, but its folder is not on your shell's PATH.", path)
        case .uninstalled(let outcomes):
            outcomes.contains(where: \.removedExistingEntry)
                ? Self.format("cli.uninstall.removed", "Removed %@.",
                              outcomes.filter(\.removedExistingEntry).map(\.destination.path).formatted(.list(type: .and)))
                : Self.format("cli.uninstall.notFound", "No cmux CLI symlink was found at %@.",
                              outcomes.first?.destination.path ?? CLIPathInstaller.Name.cmux.destination.path)
        case .offerMissing:
            Self.text("cli.offer.missing", "No `cmux` command in Terminal. Install the cmux CLI in PATH?")
        case .offerDangling(let entry, let target):
            Self.format("cli.offer.dangling", "`cmux` at %1$@ links to an app that is gone (%2$@). Point it at this app?", entry, target)
        case .offerOther(let entry, _, true):
            Self.format("cli.offer.classic", "`cmux` in Terminal runs cmux classic (%1$@). Replace makes it run this app; classic stays installed.", entry)
        case .offerOther(let entry, let bundle, false):
            Self.format("cli.offer.otherApp", "`cmux` in Terminal runs another cmux app (%1$@, from %2$@). Make it run this app?", entry, bundle)
        }
    }

    /// "Couldn't Install cmux CLI: <why>" (or Uninstall).
    public static func failed(installing: Bool, _ error: any Error) -> String {
        let title = installing ? text("cli.installFailed", "Couldn't Install cmux CLI") : text("cli.uninstallFailed", "Couldn't Uninstall cmux CLI")
        return format("cli.toast.failed", "%1$@: %2$@", title, reason(error))
    }

    static func reason(_ error: any Error) -> String {
        guard let failure = error as? CLIPathInstaller.Failure else { return error.localizedDescription }
        switch failure {
        case .bundledCLIMissing(let path):
            return format("cli.error.bundledCLIMissing", "The bundled cmux CLI was not found at %@.", path)
        case .bundleNotInstalled(let path):
            return format("cli.error.bundleNotInstalled", "cmux is running from its disk image (%@). Move it to Applications, open it from there, and try again.", path)
        case .destinationParentNotDirectory(let path):
            return format("cli.error.parentNotDirectory", "%@ is not a folder.", path)
        case .destinationInsideApp(let path):
            return format("cli.error.destinationInsideApp", "%@ is inside an app, so it was left alone.", path)
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

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "CLIInstall", bundle: .module)
    }

    static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }
}
