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

    /// Reads a target from its cmux.json text; nil when it names none. Rust reads it
    /// (`link_rules.opener_target`, cmux-config `link_rules::Target::parse`).
    public init?(_ text: String) {
        let reply = SettingsRust.answer("link_rules.opener_target", .object(["text": .string(text)]))
        guard let target = reply["target"].flatMap(Self.init(json:)) else { return nil }
        self = target
    }

    /// A target from its op form (`{kind, app?, profile?, command?}`).
    init?(json: JSONValue) {
        switch json["kind"]?.stringValue {
        case "cmux": self = .cmux
        case "system": self = .system
        case "app":
            guard let app = json["app"]?.stringValue else { return nil }
            self = .app(app, profile: json["profile"]?.stringValue)
        case "command":
            guard let command = json["command"]?.stringValue else { return nil }
            self = .command(command)
        default: return nil
        }
    }

    /// The op form of this target, which ``init(json:)`` reads back.
    var jsonValue: JSONValue {
        switch self {
        case .cmux, .system: .object(["kind": .string(kind)])
        case .app(let app, let profile):
            .object(["kind": "app", "app": .string(app), "profile": profile.map(JSONValue.string) ?? .null])
        case .command(let command): .object(["kind": "command", "command": .string(command)])
        }
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
    /// Rust answers (`link_rules.launch`).
    public func launch(for url: URL) -> TerminalLinkOpenerLaunch? {
        guard case .app = self else { return nil }
        let reply = SettingsRust.answer("link_rules.launch", .object(["target": jsonValue, "url": .string(url.absoluteString)]))
        guard let launch = reply["launch"], let app = launch["app"]?.stringValue else { return nil }
        return TerminalLinkOpenerLaunch(app: app, arguments: launch["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                        newInstance: launch["newInstance"]?.boolValue ?? false)
    }
}
