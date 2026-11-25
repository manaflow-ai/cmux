import AppKit
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings

/// `browser.open_link` (`cmux open --link`, the bundled `cmux-open-url` a cmux terminal's
/// `BROWSER` names, and its `open` / `xdg-open` shims): opens a URL a terminal program asked a
/// browser for, where `terminal.linkOpener` says (``TerminalLinkOpener``).
///
/// Params:
/// - `url` (required): an absolute http or https URL. Never put in a reply, an error or a log.
/// - `callers`: the process names of the program that asked and its parents (`aws`, `gh`),
///   which `caller:` rules match.
/// - `terminal_id`: the caller's terminal (`CMUX_TUI_TERMINAL_ID`). A cmux target opens from its
///   tab (`layout.linkPlacement`); one no tab shows refuses it with `not_found` (``LinkRouter/openTerminalLink``).
/// - `focus` (default false): false opens the tab without taking the keyboard from the terminal.
/// - `target`: a target that wins over the setting (`cmux`, `system`, `chrome@Work`), as a
///   `command:` hook prints it; a `command:` target is refused here.
/// - `origin`, `after`: as every CLI request.
///
/// A sign-in or device-code page (`SignInPage`) that no rule matches opens in cmux whatever the
/// default target, while `browser.openSignInPagesInCmux` is on (the default).
///
/// The default target `cmux` follows the link rule (`browser.openLinksInCmuxBrowser`, the host
/// list, `browser.urlsToAlwaysOpenExternally`), as a click on the link in the terminal would; a
/// rule or a `target` that names cmux opens a cmux browser tab whatever that rule says (unless the
/// cmux browser is off). The reply names the target (`cmux`, `system`, `app`, `command`) and the
/// rule that matched; a `command` reply carries the command for the CLI to run in the caller's shell.
enum TerminalLinkOpenControl {
    static let parameters: Set<String> = ["url", "callers", "terminal_id", "focus", "target", "origin", "after"]

    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("browser.open_link") { [weak services] call in
                let params = call.params
                if let unknown = params.keys.sorted().first(where: { !parameters.contains($0) }) {
                    throw ControlError.invalidParams("browser.open_link does not take params.\(unknown)")
                }
                guard let text = params["url"]?.stringValue, let url = URL(string: text),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
                    throw ControlError.invalidParams("browser.open_link needs params.url, an absolute http or https URL")
                }
                let callers = params["callers"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let setting = services?.settings?.snapshot.terminalLinkOpener ?? .fallback
                let decision: TerminalLinkOpener.Decision
                if let forced = params["target"]?.stringValue {
                    guard let target = TerminalLinkOpenerTarget(forced), target.kind != "command" else {
                        throw ControlError.invalidParams("params.target must be cmux, system, a browser or app:<name>, not a command")
                    }
                    decision = .init(target: target, rule: nil)
                } else {
                    decision = setting.decide(url, callers: callers, routing: services?.settings?.snapshot.linkRouting ?? .fallback)
                }
                let explicit = params["target"] != nil || decision.rule != nil
                let (terminal, source) = try call.terminalTab()
                let background = params["focus"]?.boolValue != true
                var reply: [String: JSONValue] = ["target": .string(decision.target.kind)]
                if let rule = decision.rule {
                    reply["rule"] = .number(Double(rule))
                    reply["rule_text"] = .string(setting.rules[rule].text)
                }
                switch decision.target {
                case .cmux:
                    guard let opened = LinkRouter.shared.openTerminalLink(url, terminal: terminal, source: source, explicit: explicit,
                                                                          background: background) else {
                        throw ControlError(code: "not_found", message: "params.terminal_id names no open terminal; nothing was opened")
                    }
                    reply["opened_in"] = .string(opened == .system ? "system" : "cmux")
                case .system:
                    LinkRouter.shared.open(url, in: .system)
                    reply["opened_in"] = "system"
                case .app:
                    guard let launch = decision.target.launch(for: url), let app = LinkMenu.application(named: launch.app) else {
                        throw ControlError(code: "not_found", message: "terminal.linkOpener names an app that is not installed")
                    }
                    open(url, launch: launch, app: app)
                    reply["opened_in"] = .string(app.deletingPathExtension().lastPathComponent)
                case .command(let command):
                    reply["command"] = .string(command)
                }
                return .value(.object(reply))
            },
        ]
    }

    /// Opens `url` with `app`: a plain open, or a launch with the profile arguments, which carry the URL.
    private static func open(_ url: URL, launch: TerminalLinkOpenerLaunch, app: URL) {
        guard !launch.arguments.isEmpty else {
            LinkRouter.shared.open(url, withApplicationAt: app)
            return
        }
        LinkRouter.shared.record("app:\(app.deletingPathExtension().lastPathComponent):\(launch.arguments.joined(separator: " "))")
        #if DEBUG
        if LinkRouter.shared.recordsExternalOpens { return }
        #endif
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = launch.arguments
        configuration.createsNewApplicationInstance = launch.newInstance
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
