public import AppKit
public import CmuxNextDaemon
import CmuxNextDesign
public import Foundation
import os

/// cmux.com's Open in cmux button: `cmux://apps/install?repo=github.com%2FOWNER%2FREPO&commit=SHA`.
/// Leo (2026-11-17), on an import that left the look unchanged: "you should be doing these for me".
/// The app only forwards the link to the bundled `cmux apps install-link URL`, which checks it (a
/// repo and a 40-hex commit, nothing else) and installs through the same path as `cmux apps
/// install`: the registry review, the pinned commit, the receipt and the undo. A link never
/// installs on its own: a theme or snippet comes back as the CLI's consent card, shown here, and
/// only the person's Install runs it with `--yes`; an extension asks with the app's own card.
@MainActor
public struct AppInstallLink {
    public init() {}
    private static let toastID = "app-install-link"
    /// The CLI fetches the repository at the pinned commit; an extension's card waits on the person.
    private static let timeout: Duration = .seconds(240)

    /// Whether `url` is an install link for this build's scheme (or the `cmux` scheme cmux.com writes):
    /// `apps/install` (an extension, theme or snippet) or `setups/install` (a setup repo).
    public static func matches(_ url: URL, linkScheme: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == linkScheme.lowercased() || scheme == "cmux" else { return false }
        return Kind(url) != nil
    }

    /// Which install a link names, and the CLI words for it.
    private enum Kind {
        case apps, setups
        init?(_ url: URL) {
            switch url.host()?.lowercased() {
            case "apps": self = .apps
            case "setups": self = .setups
            default: return nil
            }
        }
        /// `cmux apps install-link` or `cmux setup install-link`, which check the link.
        var link: [String] { self == .apps ? ["apps", "install-link"] : ["setup", "install-link"] }
        /// The install the person's yes runs on the pinned reference.
        var install: [String] { self == .apps ? ["apps", "install"] : ["setup", "install"] }
    }

    /// Runs the link through `bundled`, showing its progress, card and outcome in `window`.
    public static func open(_ link: String, bundled: BundledExecutable, window: NSWindow?) {
        show(AppInstallLinkStrings.reading, in: window, duration: timeout)
        Task { await install(link, bundled: bundled, window: window) } // task-owner: none; two bounded CLI runs and one dialog
    }

    private static func install(_ link: String, bundled: BundledExecutable, window: NSWindow?) async {
        guard let kind = URL(string: link).flatMap(Kind.init) else { return }
        guard let cli = await bundled.resolve() else { return show(AppInstallLinkStrings.noCLI, in: window, duration: .seconds(12)) }
        guard let first = await BundledCLIRun.run(cli, kind.link + [link, "--json"], timeout: timeout) else {
            return show(AppInstallLinkStrings.failed(AppInstallLinkStrings.didNotFinish), in: window, duration: .seconds(12))
        }
        if first.status == 0 { return show(summary(first.stdout), in: window, duration: .seconds(8)) }
        guard let consent = Consent(first.stderr) else {
            return show(AppInstallLinkStrings.failed(reason(first)), in: window, duration: .seconds(12))
        }
        let spec = CmuxDialogSpec(title: AppInstallLinkStrings.title, lines: consent.lines,
                                  buttons: [.cancel(AppInstallLinkStrings.cancel),
                                            CmuxDialogButton(id: "install", title: AppInstallLinkStrings.install, role: .default)],
                                  identifier: "AppInstallLink.consent")
        let answer = await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app)
        guard answer.button == "install" else { return }
        show(AppInstallLinkStrings.reading, in: window, duration: timeout)
        guard let second = await BundledCLIRun.run(cli, kind.install + [consent.reference, "--yes"], timeout: timeout) else {
            return show(AppInstallLinkStrings.failed(AppInstallLinkStrings.didNotFinish), in: window, duration: .seconds(12))
        }
        show(second.status == 0 ? summary(second.stdout) : AppInstallLinkStrings.failed(reason(second)), in: window, duration: .seconds(10))
    }

    /// The CLI's `community.needs_consent` (`details.card`) or `setup.needs_consent` (`details.text`)
    /// refusal: the card it would print, and the pinned reference.
    private struct Consent {
        let lines: [String]
        let reference: String

        init?(_ stderr: Data) {
            guard let line = BundledCLIRun.lastLine(stderr),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let code = object["code"] as? String, code == "community.needs_consent" || code == "setup.needs_consent",
                  let details = object["details"] as? [String: Any],
                  let card = (code == "setup.needs_consent" ? details["text"] : details["card"]) as? String,
                  let reference = details["reference"] as? String,
                  !reference.isEmpty, !reference.hasPrefix("-") else { return nil }
            lines = card.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.reference = reference
        }
    }

    /// What the CLI said it installed: the receipt's name from `--json`, else its first line
    /// (`installed theme Teal Twin (…)`).
    private static func summary(_ stdout: Data) -> String {
        let text = String(decoding: stdout, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
            let receipt = (object["receipt"] ?? object["installed"]) as? [String: Any]
            let name = (receipt?["name"] ?? object["name"] ?? object["id"]) as? String
            return AppInstallLinkStrings.installed(name ?? "")
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    /// The CLI's own message: its JSON error's `message`, else its last line.
    private static func reason(_ result: ProcessResult) -> String {
        guard let line = BundledCLIRun.lastLine(result.stderr) else { return BundledCLIRun.lastLine(result.stdout) ?? "exit \(result.status)" }
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let message = object["message"] as? String {
            return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        }
        return line
    }

    private static func show(_ message: String, in window: NSWindow?, duration: Duration) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app-install-link").info("install link: \(message, privacy: .public)")
            return
        }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message, duration: duration), in: window)
    }
}

enum AppInstallLinkStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AppInstallLink", bundle: .localizedModule)
    }

    static var title: String { text("appInstallLink.title", "Install from a link?") }
    static var install: String { text("appInstallLink.install", "Install") }
    static var cancel: String { text("appInstallLink.cancel", "Cancel") }
    static var reading: String { text("appInstallLink.reading", "Reading what the link installs…") }
    static var noCLI: String { text("appInstallLink.noCLI", "This build does not include the cmux CLI.") }
    static var didNotFinish: String { text("appInstallLink.didNotFinish", "it did not finish in time") }

    static func installed(_ name: String) -> String {
        String(format: text("appInstallLink.installed", "Installed %@."), name)
    }

    static func failed(_ why: String) -> String {
        String(format: text("appInstallLink.failed", "Not installed: %@"), why)
    }
}
