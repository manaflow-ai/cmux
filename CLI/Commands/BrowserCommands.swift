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
            BrowserFillCommand.self, BrowserPressCommand.self, BrowserKeyDownCommand.self,
            BrowserKeyUpCommand.self, BrowserSelectCommand.self, BrowserScrollCommand.self,
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
private enum BrowserEval: BrowserLeafName { static let commandName = "eval" }
private enum BrowserPress: BrowserLeafName { static let commandName = "press"; static let aliases = ["key"] }
private enum BrowserKeyDown: BrowserLeafName { static let commandName = "keydown" }
private enum BrowserKeyUp: BrowserLeafName { static let commandName = "keyup" }
private enum BrowserSelect: BrowserLeafName { static let commandName = "select" }
private enum BrowserScroll: BrowserLeafName { static let commandName = "scroll" }
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
private typealias BrowserReactGrabCommand = BrowserLeaf<BrowserReactGrab>
private typealias BrowserDevtoolsCommand = BrowserLeaf<BrowserDevtools>
private typealias BrowserFocusModeCommand = BrowserLeaf<BrowserFocusMode>
private typealias BrowserZoomCommand = BrowserLeaf<BrowserZoom>
private typealias BrowserHistoryCommand = BrowserLeaf<BrowserHistory>
private typealias BrowserURLCommand = BrowserLeaf<BrowserURL>
private typealias BrowserFocusWebviewCommand = BrowserLeaf<BrowserFocusWebview>
private typealias BrowserWebviewFocusedCommand = BrowserLeaf<BrowserWebviewFocused>
private typealias BrowserEvalCommand = BrowserLeaf<BrowserEval>
private typealias BrowserPressCommand = BrowserLeaf<BrowserPress>
private typealias BrowserKeyDownCommand = BrowserLeaf<BrowserKeyDown>
private typealias BrowserKeyUpCommand = BrowserLeaf<BrowserKeyUp>
private typealias BrowserSelectCommand = BrowserLeaf<BrowserSelect>
private typealias BrowserScrollCommand = BrowserLeaf<BrowserScroll>
private typealias BrowserGetCommand = BrowserLeaf<BrowserGet>
private typealias BrowserIsCommand = BrowserLeaf<BrowserIs>
private typealias BrowserFindCommand = BrowserLeaf<BrowserFind>
private typealias BrowserFrameCommand = BrowserLeaf<BrowserFrame>
private typealias BrowserDialogCommand = BrowserLeaf<BrowserDialog>
private typealias BrowserDownloadCommand = BrowserLeaf<BrowserDownload>
private typealias BrowserProfilesCommand = BrowserLeaf<BrowserProfiles>
private typealias BrowserImportCommand = BrowserLeaf<BrowserImport>
private typealias BrowserCookiesCommand = BrowserLeaf<BrowserCookies>
private typealias BrowserStorageCommand = BrowserLeaf<BrowserStorage>
private typealias BrowserTabCommand = BrowserLeaf<BrowserTab>
private typealias BrowserConsoleCommand = BrowserLeaf<BrowserConsole>
private typealias BrowserErrorsCommand = BrowserLeaf<BrowserErrors>
private typealias BrowserHighlightCommand = BrowserLeaf<BrowserHighlight>
private typealias BrowserStateCommand = BrowserLeaf<BrowserState>
private typealias BrowserAddInitScriptCommand = BrowserLeaf<BrowserAddInitScript>
private typealias BrowserAddScriptCommand = BrowserLeaf<BrowserAddScript>
private typealias BrowserAddStyleCommand = BrowserLeaf<BrowserAddStyle>
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
private typealias BrowserIdentifyCommand = BrowserLeaf<BrowserIdentify>

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
