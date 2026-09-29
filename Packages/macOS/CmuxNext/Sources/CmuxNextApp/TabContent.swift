import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextTerminal

/// What a pane shows for its selected tab.
enum TabContent {
    case terminal(TerminalEntry)
    case browser(BrowserEntry)

    var view: NSView {
        switch self {
        case .terminal(let entry): entry.session.view
        case .browser(let entry): entry.chrome
        }
    }

    /// The view that should become first responder when the pane is focused.
    var focusTarget: NSView {
        switch self {
        case .terminal(let entry): entry.session.surfaceView
        case .browser(let entry): entry.tab.contentView
        }
    }
}

/// The registry context bits a pane's content implies.
enum ContentContext {
    static func merged(_ base: ActionContext, content: TabContent?) -> ActionContext {
        var context = base
        context.subtract([.terminalFocused, .browserFocused])
        switch content {
        case .terminal: context.insert(.terminalFocused)
        case .browser: context.insert(.browserFocused)
        case nil: break
        }
        return context
    }
}

/// A live Ghostty surface attached to one daemon terminal.
final class TerminalEntry {
    /// Tab id plus the daemon generation and surface handle it attached to;
    /// a mismatch means the entry is stale (daemon restarted, tab moved).
    let validity: String
    let session: TerminalSession
    let io: DaemonTerminalIO

    init(validity: String, session: TerminalSession, io: DaemonTerminalIO) {
        self.validity = validity
        self.session = session
        self.io = io
    }

    func close() {
        session.close()
        io.close()
    }
}

/// A live WebKit page with its chrome.
final class BrowserEntry {
    let tab: any BrowserTab
    let chrome: BrowserChromeView

    init(tab: any BrowserTab) {
        self.tab = tab
        chrome = BrowserChromeView(tab: tab)
        // Shortcuts route through the action registry (browser* actions).
        chrome.handlesDefaultShortcuts = false
    }

    func close() {
        tab.close()
        chrome.removeFromSuperview()
    }
}
