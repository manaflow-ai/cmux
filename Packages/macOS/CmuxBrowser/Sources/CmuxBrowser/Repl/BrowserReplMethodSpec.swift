/// Every method the browser driver runs. The driver dispatches on this
/// type, so a method name outside it is refused before anything runs, and
/// each case must have a ``BrowserReplMethodSpec`` (the switch in ``spec``
/// is exhaustive): a new method cannot be added without its guards.
public enum BrowserReplDriverMethod: String, CaseIterable, Sendable {
    case tabsList = "tabs.list"
    case historySearch = "history.search"
    case tabsDataStore = "tabs.dataStore"
    case tabsOpen = "tabs.open"
    case tabsClose = "tabs.close"
    case tabsActivate = "tabs.activate"
    case tabBringToFront = "tab.bringToFront"
    case tabKeep = "tab.keep"
    case tabHandleEvents = "tab.handleEvents"
    case sessionName = "session.name"
    case sessionConfigure = "session.configure"
    case tabNavigate = "tab.navigate"
    case tabHistory = "tab.history"
    case tabReload = "tab.reload"
    case tabInfo = "tab.info"
    case tabSetViewport = "tab.setViewport"
    case framesList = "frames.list"
    case frameEvaluate = "frame.evaluate"
    case frameOwnerBox = "frame.ownerBox"
    case frameContentFrame = "frame.contentFrame"
    case frameContentFrames = "frame.contentFrames"
    case inputMouse = "input.mouse"
    case inputKey = "input.key"
    case inputInsertText = "input.insertText"
    case inputDrag = "input.drag"
    case inputSetFiles = "input.setFiles"
    case fileChooserRespond = "filechooser.respond"
    case dialogRespond = "dialog.respond"
    case downloadPath = "download.path"
    case tabScreenshot = "tab.screenshot"
    case tabPDF = "tab.pdf"
    case cookiesGet = "cookies.get"
    case cookiesSet = "cookies.set"
    case cookiesClear = "cookies.clear"
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case authRequest = "auth.request"
}

/// The guards one driver method gets, applied by the driver's one dispatch
/// path. Every decision they make is a ``BrowserReplDocumentAuthority``
/// verdict; this table only says which verdicts a method needs.
public struct BrowserReplMethodSpec: Sendable, Equatable {
    /// What the method does with the tab its `targetId` names.
    public enum Target: Sendable, Equatable {
        /// The tab, judged by the authority for this capability.
        case tab(BrowserReplTabCapability)
        /// No tab: the reason the method needs none.
        case none(String)
    }

    /// The page-level check before the method runs.
    public enum Page: Sendable, Equatable {
        /// The tab's page (``BrowserReplDocumentSubject/tabPage(_:)``), and in a
        /// tab the session did not create its main frame's document
        /// (``BrowserReplDocumentSubject/document(_:)``): the method reads or
        /// acts on what the page shows.
        case tabPage
        /// The URL in `params.url` (``BrowserReplDocumentSubject/load(_:)``):
        /// the method loads it.
        case loadURL
        /// No page check: why none is needed.
        case none(String)
    }

    /// The frame-level check, on the frame tree as it is when the method runs.
    public enum Frames: Sendable, Equatable {
        /// The frame under the point(s) of a pointer event.
        case pointer
        /// The frames along a drag's trail.
        case drag
        /// The frame that holds the focus.
        case focus
        /// The chooser's own frame (a `cancel` answer passes).
        case fileChooser
        /// Judged during the capture, which blanks or refuses blocked frames.
        case screenshot
        /// Every frame: any blocked one refuses it.
        case allFrames
        /// The document that opened the dialog the method answers.
        case dialogDocument
        /// Judged where its script runs (``BrowserReplFrameGate/callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``)
        /// or by the frame record it acts on: why that suffices.
        case inFrame(String)
        /// No frame check: why none is needed.
        case none(String)
    }

    public var target: Target
    public var page: Page
    public var frames: Frames
    /// Trusted input for the whole tab: blocked frames are inert while it
    /// is checked and in flight (``BrowserReplFrameGate/guardingInput(in:frames:checkFocusAfter:_:)``).
    public var guardsInput: Bool
    /// The method leaves the page: the page the tab lands on is judged
    /// after it (``BrowserReplDocumentAuthority/landedPage(_:in:)``).
    public var judgesLandedPage: Bool

    public init(target: Target, page: Page, frames: Frames, guardsInput: Bool = false, judgesLandedPage: Bool = false) {
        self.target = target
        self.page = page
        self.frames = frames
        self.guardsInput = guardsInput
        self.judgesLandedPage = judgesLandedPage
    }

    /// The tab capability the method needs, or nil when it takes no tab.
    public var capability: BrowserReplTabCapability? {
        if case .tab(let capability) = target { return capability }
        return nil
    }

    /// The spec of the method named `name`, or nil: an unknown method is
    /// refused (default deny).
    public static func spec(for name: String) -> BrowserReplMethodSpec? {
        BrowserReplDriverMethod(rawValue: name)?.spec
    }

    /// The error a method outside the table gets.
    public static func unknownMethodError(_ name: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "unsupported", message: "Unsupported driver method \(name): the driver runs only the methods its guard table names")
    }
}

extension BrowserReplDriverMethod {
    private static let noTabReason = "acts on the session or the browser, not on a tab"

    /// This method's guards.
    public var spec: BrowserReplMethodSpec {
        switch self {
        case .tabsList, .historySearch:
            return .init(target: .none("lists rows; URLs reach the session as BrowserReplListedURLs gives them"),
                         page: .none("reads no page"), frames: .none("reads no page"))
        case .tabsDataStore:
            return .init(target: .none("names a data store, not a tab's page"),
                         page: .none("reads no page"), frames: .none("reads no page"))
        case .tabsOpen:
            return .init(target: .none("opens a new tab the session creates"),
                         page: .loadURL, frames: .none("the new tab's frames are the session's, under its content rules"))
        case .tabsClose:
            return .init(target: .tab(.close), page: .none("closing reads nothing"), frames: .none("closing reads nothing"))
        case .tabsActivate, .tabBringToFront:
            return .init(target: .tab(.use), page: .none("selects the tab; reads nothing"), frames: .none("reads nothing"))
        case .tabKeep:
            return .init(target: .tab(.use), page: .none("only stops the session closing the tab at its end"), frames: .none("reads nothing"))
        case .tabHandleEvents:
            return .init(target: .tab(.use), page: .none("sets which events the session takes; each event is judged when sent (BrowserReplEventSpec)"),
                         frames: .none("reads nothing"))
        case .sessionName, .sessionConfigure:
            return .init(target: .none(Self.noTabReason), page: .none(Self.noTabReason), frames: .none(Self.noTabReason))
        case .tabNavigate:
            return .init(target: .tab(.use), page: .loadURL,
                         frames: .none("leaves the page; a user's tab that lands on a blocked page fails the call (the landed page is judged)"),
                         judgesLandedPage: true)
        case .tabHistory, .tabReload:
            return .init(target: .tab(.use), page: .none("leaves the page; the page it lands on is judged like a navigation's"),
                         frames: .none("leaves the page"), judgesLandedPage: true)
        case .tabInfo:
            return .init(target: .tab(.use), page: .none("answers the URL and title tabs.list shows from native state"),
                         frames: .inFrame("its live read of the main frame runs through the frame gate"))
        case .tabSetViewport:
            return .init(target: .tab(.use), page: .none("changes the tab's size; reads nothing"), frames: .none("reads nothing"))
        case .framesList:
            return .init(target: .tab(.use), page: .none("lists WebKit's frame records as tabs.list lists URLs"),
                         frames: .inFrame("each frame's name is read through the frame gate; a blocked frame is marked blocked"))
        case .frameOwnerBox:
            return .init(target: .tab(.use), page: .none("reads one frame element's box"),
                         frames: .inFrame("its script runs in the parent frame through the frame gate"))
        case .frameEvaluate, .frameContentFrame, .frameContentFrames:
            return .init(target: .tab(.use), page: .tabPage, frames: .inFrame("its script runs through the frame gate"))
        case .inputMouse:
            return .init(target: .tab(.use), page: .tabPage, frames: .pointer, guardsInput: true)
        case .inputDrag:
            return .init(target: .tab(.use), page: .tabPage, frames: .drag, guardsInput: true)
        case .inputKey, .inputInsertText:
            return .init(target: .tab(.use), page: .tabPage, frames: .focus, guardsInput: true)
        case .inputSetFiles:
            return .init(target: .tab(.use), page: .tabPage, frames: .inFrame("files are set on an element through the frame gate"))
        case .fileChooserRespond:
            return .init(target: .tab(.use), page: .tabPage, frames: .fileChooser)
        case .dialogRespond:
            return .init(target: .tab(.use), page: .none("a dialog is answered while page script is stopped; its own document is judged"),
                         frames: .dialogDocument)
        case .downloadPath:
            return .init(target: .none("reads the session's own download ledger"),
                         page: .none("the download was judged by every hop and its initiator when it started (BrowserReplDownloadSource)"),
                         frames: .none("reads no page"))
        case .tabScreenshot:
            return .init(target: .tab(.use), page: .tabPage, frames: .screenshot)
        case .tabPDF:
            return .init(target: .tab(.use), page: .tabPage, frames: .allFrames)
        case .cookiesGet, .cookiesSet:
            return .init(target: .tab(.use), page: .none("the tab only picks the data store; each URL and cookie domain is judged by the policy"),
                         frames: .none("reads no page"))
        case .cookiesClear:
            return .init(target: .tab(.use), page: .tabPage, frames: .none("its scope is the tab's site, judged by the page check"))
        case .clipboardRead, .clipboardWrite:
            return .init(target: .tab(.use), page: .tabPage,
                         frames: .inFrame("a page's write to the tab's clipboard is refused from a frame the creating session's policy blocks"))
        case .authRequest:
            return .init(target: .tab(.use), page: .tabPage, frames: .inFrame("the sign-in frame's record and its document are judged before the sheet"))
        }
    }
}

/// Every event the browser driver sends. A tab's events are sent through
/// this type, and the driver drops any other name before it reaches a
/// session; each case must have a ``BrowserReplEventSpec``.
public enum BrowserReplDriverEvent: String, CaseIterable, Sendable {
    case tabCreated = "tab.created"
    case tabClosed = "tab.closed"
    case tabReplaced = "tab.replaced"
    case tabCrashed = "tab.crashed"
    case navigationBlocked = "navigation.blocked"
    case request
    case response
    case requestFailed = "requestfailed"
    case requestFinished = "requestfinished"
    case console
    case pageError = "pageerror"
    case dialogOpened = "dialog.opened"
    case fileChooserOpened = "filechooser.opened"
    case downloadStarted = "download.started"
    case downloadFinished = "download.finished"
}

/// Who receives one driver event, and what judges it.
public struct BrowserReplEventSpec: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        /// Every attached session: the tab's own lifecycle, which reads no
        /// page. The reason.
        case everyAttached(String)
        /// The one session it concerns (a new tab to the session it was
        /// opened for). The reason.
        case oneSession(String)
        /// The sessions the network event belongs to
        /// (``BrowserReplTabOwnership/networkRecipients(event:requestID:)``),
        /// credentials only for the tab's creator.
        case network
        /// The sessions whose authority allows the frame document that sent
        /// it (a read of that document).
        case fromDocument
        /// The one session it is routed to, never one whose authority
        /// refuses the document of the frame that opened it.
        case routedFromDocument
        /// The session the download is routed to, judged by its source
        /// (every hop and its initiator, ``BrowserReplDownloadSource``).
        case download
    }

    public var delivery: Delivery

    public init(delivery: Delivery) {
        self.delivery = delivery
    }

    /// The spec of the event named `name`, or nil: an unknown event is dropped.
    public static func spec(for name: String) -> BrowserReplEventSpec? {
        BrowserReplDriverEvent(rawValue: name)?.spec
    }
}

extension BrowserReplDriverEvent {
    /// This event's delivery.
    public var spec: BrowserReplEventSpec {
        switch self {
        case .tabClosed, .tabReplaced, .tabCrashed:
            return .init(delivery: .everyAttached("the tab's lifecycle; carries no page content"))
        case .navigationBlocked:
            return .init(delivery: .everyAttached("names the URL the session's own policy refused in a tab it created"))
        case .tabCreated:
            return .init(delivery: .oneSession("a popup tab goes to the session it was routed to (BrowserReplPopupRoute)"))
        case .request, .response, .requestFailed, .requestFinished:
            return .init(delivery: .network)
        case .console, .pageError:
            return .init(delivery: .fromDocument)
        case .dialogOpened, .fileChooserOpened:
            return .init(delivery: .routedFromDocument)
        case .downloadStarted, .downloadFinished:
            return .init(delivery: .download)
        }
    }

    /// Whether this event may be sent through a path that delivers it as
    /// `delivery`: a path that does not match the table drops it.
    public func isDelivered(as delivery: BrowserReplEventSpec.Delivery) -> Bool {
        switch (spec.delivery, delivery) {
        case (.everyAttached, .everyAttached), (.oneSession, .oneSession), (.network, .network),
             (.fromDocument, .fromDocument), (.routedFromDocument, .routedFromDocument), (.download, .download):
            return true
        default:
            return false
        }
    }
}
