import ArgumentParser
import Foundation

/// Routes browser facade declarations through the established browser command runner.
private protocol LegacyBrowserCommand: ParsableCommand {}

extension LegacyBrowserCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol BrowserLeafName {
    static var commandName: String { get }
    static var aliases: [String] { get }
}

extension BrowserLeafName {
    static var aliases: [String] { [] }
}

/// Routing options accepted by browser verbs that operate on a browser surface.
struct BrowserTargetOptions: ParsableArguments {
    @Option(name: .customLong("surface"), completion: .custom(CompletionCandidates.surfaces)) var surface: String?
}

/// Options accepted only while creating a browser split.
struct BrowserOpenOptions: ParsableArguments {
    @Option(
        name: .customLong("profile"),
        help: ArgumentHelp(String(localized: "cli.browser.profile.option", defaultValue: "[--profile <name|uuid>]"))
    ) var profile: String?
    @Option(name: .customLong("focus")) var focus: String?
}

/// `browser open-split` only accepts a profile selector.
struct BrowserOpenSplitOptions: ParsableArguments {
    @Option(
        name: .customLong("profile"),
        help: ArgumentHelp(String(localized: "cli.browser.profile.option", defaultValue: "[--profile <name|uuid>]"))
    ) var profile: String?
}

/// Options for browser navigation and element actions that can request a snapshot.
struct BrowserSnapshotAfterOptions: ParsableArguments {
    @OptionGroup var target: BrowserTargetOptions
    @Flag(name: .customLong("snapshot-after")) var snapshotAfter = false
}

/// Options for `browser snapshot`.
struct BrowserSnapshotOptions: ParsableArguments {
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("selector")) var selector: String?
    @Option(name: .customLong("max-depth")) var maxDepth: Int?
    @Flag(name: [.customLong("interactive"), .customShort("i")]) var interactive = false
    @Flag(name: .customLong("cursor")) var cursor = false
    @Flag(name: .customLong("compact")) var compact = false
}

/// Options for `browser wait`.
struct BrowserWaitOptions: ParsableArguments {
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("selector")) var selector: String?
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("text")) var text: String?
    @Option(name: .customLong("timeout-ms")) var timeoutMilliseconds: Int?
    @Option(name: .customLong("timeout")) var timeout: Double?
    @Option(name: .customLong("load-state"), completion: .list(["interactive", "complete"])) var loadState: String?
    @Option(name: .customLong("function")) var function: String?
}

/// A browser verb whose detailed option validation remains in the legacy runner.
private struct BrowserLeaf<Name: BrowserLeafName>: LegacyBrowserCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: Name.commandName, helpNames: [], aliases: Name.aliases)
    }
}

protocol BrowserLegacyAliasName {
    static var commandName: String { get }
    static var abstract: String { get }
}

extension BrowserLegacyAliasName {
    static func legacyAbstract(for browserCommand: String) -> String {
        let format = String(
            localized: "cli.browser.legacyAlias.abstract",
            defaultValue: "Legacy alias for 'cmux browser %@'. Run 'cmux browser --help' for details."
        )
        return String(format: format, locale: .current, browserCommand)
    }
}

/// A top-level compatibility alias for a browser subcommand.
struct BrowserLegacyAlias<Name: BrowserLegacyAliasName>: LegacyBrowserCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: Name.commandName, abstract: Name.abstract, helpNames: [])
    }
}

struct BrowserCommand: LegacyBrowserCommand {
    @Option(name: .customLong("surface"), completion: .custom(CompletionCandidates.surfaces)) var surface: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "browser",
        subcommands: [
            BrowserDisableCommand.self, BrowserEnableCommand.self, BrowserStatusCommand.self,
            BrowserOpenCommand.self, BrowserOpenSplitCommand.self, BrowserNewCommand.self,
            BrowserGotoCommand.self, BrowserBackCommand.self, BrowserForwardCommand.self,
            BrowserReloadCommand.self, BrowserReactGrabCommand.self, BrowserDevtoolsCommand.self,
            BrowserFocusModeCommand.self, BrowserDesignModeCommand.self, BrowserZoomCommand.self,
            BrowserHistoryCommand.self, BrowserURLCommand.self, BrowserFocusWebviewCommand.self,
            BrowserWebviewFocusedCommand.self, BrowserSnapshotCommand.self, BrowserEvalCommand.self,
            BrowserWaitCommand.self, BrowserSelectorActionCommand.self, BrowserTypeCommand.self,
            BrowserFillCommand.self, BrowserKeyCommand.self, BrowserSelectCommand.self,
            BrowserScrollCommand.self,
            BrowserScreenshotCommand.self, BrowserGetCommand.self, BrowserIsCommand.self,
            BrowserFindCommand.self, BrowserFrameCommand.self, BrowserDialogCommand.self,
            BrowserDownloadCommand.self, BrowserProfilesCommand.self, BrowserImportCommand.self,
            BrowserCookiesCommand.self, BrowserStorageCommand.self, BrowserTabCommand.self,
            BrowserConsoleCommand.self, BrowserErrorsCommand.self, BrowserHighlightCommand.self,
            BrowserStateCommand.self, BrowserAddInitScriptCommand.self, BrowserAddScriptCommand.self,
            BrowserAddStyleCommand.self, BrowserViewportCommand.self, BrowserGeolocationCommand.self,
            BrowserOfflineCommand.self, BrowserTraceCommand.self, BrowserNetworkCommand.self,
            BrowserScreencastCommand.self, BrowserInputCommand.self, BrowserInputMouseCommand.self,
            BrowserInputKeyboardCommand.self, BrowserInputTouchCommand.self, BrowserIdentifyCommand.self,
        ],
        helpNames: []
    )
}

struct BrowserOpenCommand: LegacyBrowserCommand {
    @Argument var url: String?
    @OptionGroup var options: BrowserOpenOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open", helpNames: [])
}

struct BrowserOpenSplitCommand: LegacyBrowserCommand {
    @Argument var url: String?
    @OptionGroup var options: BrowserOpenSplitOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open-split", helpNames: [])
}

struct BrowserDesignModeCommand: LegacyBrowserCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "design-mode",
        abstract: String(localized: "cli.browser.designMode.help", defaultValue: "browser design-mode enable|disable|toggle|status [--surface <id>]"),
        helpNames: []
    )
}

struct BrowserGotoCommand: LegacyBrowserCommand {
    @Argument var url: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "goto", helpNames: [], aliases: ["navigate"])
}

struct BrowserSnapshotCommand: LegacyBrowserCommand {
    @OptionGroup var options: BrowserSnapshotOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "snapshot", helpNames: [])
}

struct BrowserWaitCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @OptionGroup var options: BrowserWaitOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "wait", helpNames: [])
}

struct BrowserSelectorActionCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "click", helpNames: [], aliases: ["dblclick", "hover", "focus", "check", "uncheck", "scroll-into-view", "scrollintoview", "scrollinto"])
}

struct BrowserTypeCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @Argument var text: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "type", helpNames: [])
}

struct BrowserFillCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @Argument var text: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "fill", helpNames: [])
}

struct BrowserScreenshotCommand: LegacyBrowserCommand {
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("out"), completion: .file()) var out: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "screenshot", helpNames: [])
}

struct BrowserEvalCommand: LegacyBrowserCommand {
    @Argument var script: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "eval", helpNames: [])
}

struct BrowserKeyCommand: LegacyBrowserCommand {
    @Argument var key: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "press", helpNames: [], aliases: ["key", "keydown", "keyup"])
}

struct BrowserSelectCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @Argument var value: String?
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "select", helpNames: [])
}

struct BrowserScrollCommand: LegacyBrowserCommand {
    @OptionGroup var options: BrowserSnapshotAfterOptions
    @Option(name: .customLong("selector")) var selector: String?
    @Option(name: .customLong("dx")) var dx: Int?
    @Option(name: .customLong("dy")) var dy: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "scroll", helpNames: [])
}

// The commands below deliberately retain the legacy runner for execution, but
// declare their accepted syntax here so ArgumentParser can expose accurate help
// and completion metadata. `arguments` forwards any positional tail that the
// legacy command still interprets (for example profile names and CSS values).
struct BrowserReactGrabCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("return-to"), completion: .custom(CompletionCandidates.surfaces)) var returnTo: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "react-grab", helpNames: [], aliases: ["reactgrab"])
}

struct BrowserDevtoolsCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "devtools", helpNames: [], aliases: ["dev-tools"])
}

struct BrowserFocusModeCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-mode", helpNames: [])
}

struct BrowserZoomCommand: LegacyBrowserCommand {
    @Argument var factor: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "zoom", helpNames: [])
}

struct BrowserHistoryCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Flag(name: .customLong("force")) var force = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "history", helpNames: [])
}

struct BrowserGetCommand: LegacyBrowserCommand {
    @Argument var property: String?
    @Argument var selector: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("attr")) var attribute: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "get", helpNames: [])
}

struct BrowserIsCommand: LegacyBrowserCommand {
    @Argument var property: String?
    @Argument var selector: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "is", helpNames: [])
}

struct BrowserFindCommand: LegacyBrowserCommand {
    @Argument var locator: String?
    @Argument var value: String?
    @Argument var selector: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "find", helpNames: [])
}

struct BrowserFrameCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "frame", helpNames: [])
}

struct BrowserDialogCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Argument var text: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "dialog", helpNames: [])
}

struct BrowserDownloadCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("path"), completion: .file()) var path: String?
    @Option(name: .customLong("timeout-ms")) var timeoutMilliseconds: Int?
    @Option(name: .customLong("timeout")) var timeout: Double?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "download", helpNames: [])
}

struct BrowserProfilesCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "profiles", helpNames: [], aliases: ["profile"])
}

struct BrowserImportCommand: LegacyBrowserCommand {
    @Option(name: [.customLong("from"), .customLong("browser"), .customLong("source")]) var source: String?
    @Option(name: [.customLong("profile"), .customLong("source-profile")]) var sourceProfile: [String] = []
    @Option(name: [.customLong("to"), .customLong("to-profile"), .customLong("destination-profile")]) var destinationProfile: String?
    @Option(name: [.customLong("domain"), .customLong("domains")]) var domain: [String] = []
    @Flag(name: [.customLong("interactive")]) var interactive = false
    @Flag(name: [.customLong("non-interactive"), .customLong("noninteractive"), .customLong("yes"), .customShort("y")]) var nonInteractive = false
    @Flag(name: .customLong("all-profiles")) var allProfiles = false
    @Flag(name: [.customLong("create-profile"), .customLong("create-destination-profile")]) var createProfile = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "import", helpNames: [])
}

struct BrowserCookiesCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Argument var name: String?
    @Argument var value: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("domain")) var domain: String?
    @Option(name: .customLong("path"), completion: .file()) var path: String?
    @Option(name: .customLong("expires")) var expires: Int?
    @Flag(name: .customLong("secure")) var secure = false
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "cookies", helpNames: [])
}

struct BrowserStorageCommand: LegacyBrowserCommand {
    @Argument var type: String?
    @Argument var action: String?
    @Argument var key: String?
    @Argument var value: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "storage", helpNames: [])
}

struct BrowserTabCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Argument var targetTab: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tab", helpNames: [])
}

struct BrowserConsoleCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "console", helpNames: [])
}

struct BrowserErrorsCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "errors", helpNames: [])
}

struct BrowserHighlightCommand: LegacyBrowserCommand {
    @Argument var selector: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("selector")) var selectorOption: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "highlight", helpNames: [])
}

struct BrowserStateCommand: LegacyBrowserCommand {
    @Argument var action: String?
    @Argument(completion: .file()) var path: String?
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "state", helpNames: [])
}

struct BrowserAddInitScriptCommand: LegacyBrowserCommand {
    @Argument var script: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("script")) var scriptOption: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "addinitscript", helpNames: [])
}

struct BrowserAddScriptCommand: LegacyBrowserCommand {
    @Argument var script: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("script")) var scriptOption: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "addscript", helpNames: [])
}

struct BrowserAddStyleCommand: LegacyBrowserCommand {
    @Argument var css: String?
    @OptionGroup var target: BrowserTargetOptions
    @Option(name: .customLong("css")) var cssOption: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "addstyle", helpNames: [])
}

struct BrowserIdentifyCommand: LegacyBrowserCommand {
    @OptionGroup var target: BrowserTargetOptions
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "identify", helpNames: [])
}

private enum BrowserDisable: BrowserLeafName { static let commandName = "disable" }
private enum BrowserEnable: BrowserLeafName { static let commandName = "enable" }
private enum BrowserStatus: BrowserLeafName { static let commandName = "status" }
private enum BrowserNew: BrowserLeafName { static let commandName = "new" }
private enum BrowserBack: BrowserLeafName { static let commandName = "back" }
private enum BrowserForward: BrowserLeafName { static let commandName = "forward" }
private enum BrowserReload: BrowserLeafName { static let commandName = "reload" }
private enum BrowserReactGrab: BrowserLeafName { static let commandName = "react-grab"; static let aliases = ["reactgrab"] }
private enum BrowserDevtools: BrowserLeafName { static let commandName = "devtools"; static let aliases = ["dev-tools"] }
private enum BrowserFocusMode: BrowserLeafName { static let commandName = "focus-mode" }
private enum BrowserZoom: BrowserLeafName { static let commandName = "zoom" }
private enum BrowserHistory: BrowserLeafName { static let commandName = "history" }
private enum BrowserURL: BrowserLeafName { static let commandName = "url"; static let aliases = ["get-url"] }
private enum BrowserFocusWebview: BrowserLeafName { static let commandName = "focus-webview"; static let aliases = ["focus_webview"] }
private enum BrowserWebviewFocused: BrowserLeafName { static let commandName = "is-webview-focused"; static let aliases = ["is_webview_focused"] }
private enum BrowserGet: BrowserLeafName { static let commandName = "get" }
private enum BrowserIs: BrowserLeafName { static let commandName = "is" }
private enum BrowserFind: BrowserLeafName { static let commandName = "find" }
private enum BrowserFrame: BrowserLeafName { static let commandName = "frame" }
private enum BrowserDialog: BrowserLeafName { static let commandName = "dialog" }
private enum BrowserDownload: BrowserLeafName { static let commandName = "download" }
private enum BrowserProfiles: BrowserLeafName { static let commandName = "profiles"; static let aliases = ["profile"] }
private enum BrowserImport: BrowserLeafName { static let commandName = "import" }
private enum BrowserCookies: BrowserLeafName { static let commandName = "cookies" }
private enum BrowserStorage: BrowserLeafName { static let commandName = "storage" }
private enum BrowserTab: BrowserLeafName { static let commandName = "tab" }
private enum BrowserConsole: BrowserLeafName { static let commandName = "console" }
private enum BrowserErrors: BrowserLeafName { static let commandName = "errors" }
private enum BrowserHighlight: BrowserLeafName { static let commandName = "highlight" }
private enum BrowserState: BrowserLeafName { static let commandName = "state" }
private enum BrowserAddInitScript: BrowserLeafName { static let commandName = "addinitscript" }
private enum BrowserAddScript: BrowserLeafName { static let commandName = "addscript" }
private enum BrowserAddStyle: BrowserLeafName { static let commandName = "addstyle" }
private enum BrowserViewport: BrowserLeafName { static let commandName = "viewport" }
private enum BrowserGeolocation: BrowserLeafName { static let commandName = "geolocation"; static let aliases = ["geo"] }
private enum BrowserOffline: BrowserLeafName { static let commandName = "offline" }
private enum BrowserTrace: BrowserLeafName { static let commandName = "trace" }
private enum BrowserNetwork: BrowserLeafName { static let commandName = "network" }
private enum BrowserScreencast: BrowserLeafName { static let commandName = "screencast" }
private enum BrowserInput: BrowserLeafName { static let commandName = "input" }
private enum BrowserInputMouse: BrowserLeafName { static let commandName = "input_mouse" }
private enum BrowserInputKeyboard: BrowserLeafName { static let commandName = "input_keyboard" }
private enum BrowserInputTouch: BrowserLeafName { static let commandName = "input_touch" }
private enum BrowserIdentify: BrowserLeafName { static let commandName = "identify" }

private typealias BrowserDisableCommand = BrowserLeaf<BrowserDisable>
private typealias BrowserEnableCommand = BrowserLeaf<BrowserEnable>
private typealias BrowserStatusCommand = BrowserLeaf<BrowserStatus>
private typealias BrowserNewCommand = BrowserLeaf<BrowserNew>
private typealias BrowserBackCommand = BrowserLeaf<BrowserBack>
private typealias BrowserForwardCommand = BrowserLeaf<BrowserForward>
private typealias BrowserReloadCommand = BrowserLeaf<BrowserReload>
private typealias BrowserURLCommand = BrowserLeaf<BrowserURL>
private typealias BrowserFocusWebviewCommand = BrowserLeaf<BrowserFocusWebview>
private typealias BrowserWebviewFocusedCommand = BrowserLeaf<BrowserWebviewFocused>
private typealias BrowserViewportCommand = BrowserLeaf<BrowserViewport>
private typealias BrowserGeolocationCommand = BrowserLeaf<BrowserGeolocation>
private typealias BrowserOfflineCommand = BrowserLeaf<BrowserOffline>
private typealias BrowserTraceCommand = BrowserLeaf<BrowserTrace>
private typealias BrowserNetworkCommand = BrowserLeaf<BrowserNetwork>
private typealias BrowserScreencastCommand = BrowserLeaf<BrowserScreencast>
private typealias BrowserInputCommand = BrowserLeaf<BrowserInput>
private typealias BrowserInputMouseCommand = BrowserLeaf<BrowserInputMouse>
private typealias BrowserInputKeyboardCommand = BrowserLeaf<BrowserInputKeyboard>
private typealias BrowserInputTouchCommand = BrowserLeaf<BrowserInputTouch>

enum OpenBrowserAlias: BrowserLegacyAliasName {
    static let commandName = "open-browser"
    static let abstract = legacyAbstract(for: "open")
}
enum NavigateAlias: BrowserLegacyAliasName {
    static let commandName = "navigate"
    static let abstract = legacyAbstract(for: "navigate")
}
enum BrowserBackAlias: BrowserLegacyAliasName {
    static let commandName = "browser-back"
    static let abstract = legacyAbstract(for: "back")
}
enum BrowserForwardAlias: BrowserLegacyAliasName {
    static let commandName = "browser-forward"
    static let abstract = legacyAbstract(for: "forward")
}
enum BrowserReloadAlias: BrowserLegacyAliasName {
    static let commandName = "browser-reload"
    static let abstract = legacyAbstract(for: "reload")
}
enum BrowserStatusAlias: BrowserLegacyAliasName {
    static let commandName = "browser-status"
    static let abstract = legacyAbstract(for: "status")
}
enum GetURLAlias: BrowserLegacyAliasName {
    static let commandName = "get-url"
    static let abstract = legacyAbstract(for: "get-url")
}
enum FocusWebviewAlias: BrowserLegacyAliasName {
    static let commandName = "focus-webview"
    static let abstract = legacyAbstract(for: "focus-webview")
}
enum WebviewFocusedAlias: BrowserLegacyAliasName {
    static let commandName = "is-webview-focused"
    static let abstract = legacyAbstract(for: "is-webview-focused")
}
enum DisableBrowserAlias: BrowserLegacyAliasName {
    static let commandName = "disable-browser"
    static let abstract = legacyAbstract(for: "disable")
}
enum EnableBrowserAlias: BrowserLegacyAliasName {
    static let commandName = "enable-browser"
    static let abstract = legacyAbstract(for: "enable")
}

typealias OpenBrowserCommand = BrowserLegacyAlias<OpenBrowserAlias>
typealias NavigateCommand = BrowserLegacyAlias<NavigateAlias>
typealias BrowserBackLegacyCommand = BrowserLegacyAlias<BrowserBackAlias>
typealias BrowserForwardLegacyCommand = BrowserLegacyAlias<BrowserForwardAlias>
typealias BrowserReloadLegacyCommand = BrowserLegacyAlias<BrowserReloadAlias>
typealias BrowserStatusLegacyCommand = BrowserLegacyAlias<BrowserStatusAlias>
typealias GetURLCommand = BrowserLegacyAlias<GetURLAlias>
typealias FocusWebviewLegacyCommand = BrowserLegacyAlias<FocusWebviewAlias>
typealias WebviewFocusedLegacyCommand = BrowserLegacyAlias<WebviewFocusedAlias>
typealias DisableBrowserCommand = BrowserLegacyAlias<DisableBrowserAlias>
typealias EnableBrowserCommand = BrowserLegacyAlias<EnableBrowserAlias>
