extension CMUXCLI {
    enum BrowserSubcommandName: String, CLICommandName {
        case identify
        case disable
        case enable
        case status
        case open
        case openSplit = "open-split"
        case new
        case goto
        case navigate
        case back
        case forward
        case reload
        case url
        case getURL = "get-url"
        case focusWebview = "focus-webview"
        case focusWebviewUnderscore = "focus_webview"
        case isWebviewFocused = "is-webview-focused"
        case isWebviewFocusedUnderscore = "is_webview_focused"
        case snapshot
        case eval
        case wait
        case click
        case dblclick
        case hover
        case focus
        case check
        case uncheck
        case scrollIntoView = "scroll-into-view"
        case scrollinto
        case scrollintoview
        case type
        case fill
        case press
        case key
        case keydown
        case keyup
        case select
        case scroll
        case screenshot
        case get
        case isCommand = "is"
        case find
        case frame
        case dialog
        case download
        case cookies
        case storage
        case tab
        case console
        case errors
        case highlight
        case state
        case addinitscript
        case addscript
        case addstyle
        case viewport
        case geolocation
        case geo
        case offline
        case trace
        case network
        case screencast
        case input
        case inputMouse = "input_mouse"
        case inputKeyboard = "input_keyboard"
        case inputTouch = "input_touch"
    }

    enum BrowserGetSubcommandName: String, CLICommandName {
        case url
        case title
        case text
        case html
        case value
        case attr
        case count
        case box
        case styles
    }

    enum BrowserIsSubcommandName: String, CLICommandName {
        case visible
        case enabled
        case checked
    }

    enum BrowserFindSubcommandName: String, CLICommandName {
        case role
        case text
        case label
        case placeholder
        case alt
        case title
        case testid
        case first
        case last
        case nth
    }

    enum BrowserFrameSubcommandName: String, CLICommandName {
        case main
    }

    enum BrowserDialogSubcommandName: String, CLICommandName {
        case accept
        case dismiss
    }

    enum BrowserDownloadSubcommandName: String, CLICommandName {
        case wait
    }

    enum BrowserCookiesSubcommandName: String, CLICommandName {
        case get
        case set
        case clear
    }

    enum BrowserStorageTypeName: String, CLICommandName {
        case local
        case session
    }

    enum BrowserStorageOperationName: String, CLICommandName {
        case get
        case set
        case clear
    }

    enum BrowserTabSubcommandName: String, CLICommandName {
        case new
        case list
        case switchCommand = "switch"
        case close
    }

    enum BrowserLogSubcommandName: String, CLICommandName {
        case list
        case clear
    }

    enum BrowserStateSubcommandName: String, CLICommandName {
        case save
        case load
    }

    enum BrowserTraceSubcommandName: String, CLICommandName {
        case start
        case stop
    }

    enum BrowserNetworkSubcommandName: String, CLICommandName {
        case route
        case unroute
        case requests
    }

    enum BrowserScreencastSubcommandName: String, CLICommandName {
        case start
        case stop
    }

    enum BrowserInputSubcommandName: String, CLICommandName {
        case mouse
        case keyboard
        case touch
    }
}
