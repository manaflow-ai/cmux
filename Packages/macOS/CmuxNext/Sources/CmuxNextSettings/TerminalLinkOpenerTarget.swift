public import Foundation

/// Where a URL that a program in a cmux terminal opens goes (``TerminalLinkOpener``).
///
/// Written in cmux.json as one string:
///
/// | Text | Target |
/// | --- | --- |
/// | `cmux` | A cmux browser tab, by the link rule (`browser.openLinksInCmuxBrowser`, `layout.linkPlacement`). |
/// | `system` | The macOS default browser. |
/// | `chrome`, `safari`, `arc`, `firefox`, `edge`, `brave` | That browser app. |
/// | `app:<name, bundle ID or path>` | Any app, such as `app:Zen` or `app:/Applications/Vivaldi.app`. |
/// | `chrome@Profile 1`, `app:Firefox@work` | The app with a profile (Chromium browsers and Firefox). |
/// | `command:<shell command>` | A command that gets the URL and decides (``command(_:)``). |
public nonisolated enum TerminalLinkOpenerTarget: Sendable, Hashable {
    /// A cmux browser tab, placed and filtered by the link rule (``LinkRouting``).
    case cmux
    /// The macOS default browser.
    case system
    /// An app by name, bundle ID or `.app` path, with an optional browser profile.
    case app(String, profile: String?)
    /// A shell command run in the caller's terminal environment with the URL as `$1` (also
    /// `CMUX_LINK_URL`) and the caller's process names in `CMUX_LINK_CALLERS`. It opens the
    /// URL itself (exit 0, no output), or prints one target on its first line (`cmux`,
    /// `system`, `chrome@Work`, ...) for cmux to open the URL in.
    case command(String)

    /// The app names the short presets stand for.
    public static let presets: [String: String] = [
        "chrome": "Google Chrome", "safari": "Safari", "arc": "Arc",
        "firefox": "Firefox", "edge": "Microsoft Edge", "brave": "Brave Browser",
    ]

    /// Reads a target from its cmux.json text; nil when it names none.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        switch lower {
        case "cmux": self = .cmux; return
        case "system", "default": self = .system; return
        default: break
        }
        if lower.hasPrefix("command:") {
            let command = trimmed.dropFirst("command:".count).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            self = .command(command)
            return
        }
        var body = trimmed
        var profile: String?
        if let at = body.lastIndex(of: "@") {
            let name = body[body.index(after: at)...].trimmingCharacters(in: .whitespaces)
            profile = name.isEmpty ? nil : name
            body = String(body[..<at])
        }
        if body.lowercased().hasPrefix("app:") {
            let app = body.dropFirst("app:".count).trimmingCharacters(in: .whitespaces)
            guard !app.isEmpty else { return nil }
            self = .app(app, profile: profile)
            return
        }
        guard let app = Self.presets[body.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        self = .app(app, profile: profile)
    }

    /// The word a control reply names this target by: `cmux`, `system`, `app` or `command`.
    public var kind: String {
        switch self {
        case .cmux: "cmux"
        case .system: "system"
        case .app: "app"
        case .command: "command"
        }
    }

    /// How an ``app(_:profile:)`` target launches for `url`: the app, the launch arguments and
    /// whether a new instance is asked for. A profile is passed only to browsers that take one on
    /// the command line, and then as a new instance, since a running app ignores the arguments of
    /// a plain open: Chromium browsers (`--profile-directory=`, which hands the URL to the running
    /// browser) and Firefox (`-P`). Nil for other targets.
    public func launch(for url: URL) -> TerminalLinkOpenerLaunch? {
        guard case .app(let app, let profile) = self else { return nil }
        let name = app.lowercased()
        guard let profile else { return TerminalLinkOpenerLaunch(app: app, arguments: [], newInstance: false) }
        if ["chrome", "chromium", "edge", "brave", "vivaldi", "opera"].contains(where: name.contains) {
            return TerminalLinkOpenerLaunch(app: app, arguments: ["--profile-directory=\(profile)", url.absoluteString], newInstance: true)
        }
        if ["firefox", "librewolf", "zen"].contains(where: name.contains) {
            return TerminalLinkOpenerLaunch(app: app, arguments: ["-P", profile, "-new-tab", url.absoluteString], newInstance: true)
        }
        return TerminalLinkOpenerLaunch(app: app, arguments: [], newInstance: false)
    }
}
