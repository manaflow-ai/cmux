public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation
import WebKit

/// Everything a page view is made from, handed to ``WebUIHost/open(_:)``: the fields of the
/// `PageWebView(...)` initializers, field by field.
public struct PageOpenRequest {
    /// The page (its origin, ops and policy).
    public var descriptor: PageDescriptor
    /// The directory holding the page's `index.html`. Nil serves the page from its own root (the
    /// DEBUG override, else its bundled directory, else the root registered for its id). A
    /// first-party page given another root is refused (``PageWebView/mayServe(_:from:)``).
    public var root: URL?
    /// The op routes the page may call.
    public var routes: [PageRoute]
    /// The route the page opens at (`#/start`; a leading `#` is added when missing).
    public var route: String?
    /// `data-*` attributes of `<html>`, set before the page's code runs.
    public var documentAttributes: [String: String]
    /// Engine options; each engine maps the ones it has.
    public var options: PageEngineOptions
    /// The initial theme surface (``PageWebView/themeSurface``).
    public var surface: SurfaceKind?
    /// Answers the descriptor's dynamic prefixes (a 404 without one).
    public var dynamicResources: (any PageDynamicResourceSource)?
    /// The agent chat open the page shows (``PageWebView/chatOpen``), known before its document starts.
    public var chatOpen: ChatOpenStages?
    /// The pane window a Chromium page joins (``PageWebView/chromiumWindow``); nil gives it one of its
    /// own. The pane that shows a page tab sets it when it shows the tab, so an opener may leave it nil.
    public var chromiumWindow: PageChromiumWindow?

    public init(descriptor: PageDescriptor, root: URL? = nil, routes: [PageRoute], route: String? = nil,
                documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil,
                chatOpen: ChatOpenStages? = nil, chromiumWindow: PageChromiumWindow? = nil) {
        self.descriptor = descriptor
        self.root = root
        self.routes = routes
        self.route = route
        self.documentAttributes = documentAttributes
        self.options = options
        self.surface = surface
        self.dynamicResources = dynamicResources
        self.chatOpen = chatOpen
        self.chromiumWindow = chromiumWindow
    }
}

extension PageWebView {
    /// The one path that makes a loading page view: ``WebUIHost/open(_:)`` and the public
    /// initializers (until p13-webui-010 makes them internal) both come here.
    ///
    /// - Parameters:
    ///   - request: The page to make.
    ///   - chromium: Makes the page's Chromium view when the policy picks Chromium; nil keeps it on WebKit.
    ///   - openPanel: Answers the page's `<input type="file">` on WebKit; nil: a file input does nothing.
    ///   - registry: Lists the view for the debug verbs.
    ///   - processGroups: The host's shared WebKit processes, which a page that asks for them
    ///     (``PageEngineOptions/sharesWebKitProcess``) joins when it shows in WebKit.
    ///   - startsAtFirstShow: The document (and its renderer) starts at the view's first show, not now.
    ///   - deadlines: The app's deadline scheduler (``PageWebView/deadlines``); a test leaves the default, its own.
    convenience init?(request: PageOpenRequest, chromium: (any PageChromiumHosting)?,
                      openPanel: MadeAheadOpenPanel?, registry: PageRegistry, processGroups: WebProcessGroups? = nil,
                      startsAtFirstShow: Bool = false,
                      deadlines: MainDeadlineScheduler = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))) {
        let requested = ProcessInfo.processInfo.systemUptime
        let root: URL
        if let explicit = request.root {
            guard Self.mayServe(request.descriptor, from: explicit) else { return nil }
            root = explicit
        } else {
            guard let served = Self.servedRoot(for: request.descriptor) else { return nil }
            root = served
        }
        let handler = PageSchemeHandler(page: request.descriptor, root: root, dynamicSource: request.dynamicResources)
        let groups = request.options.sharesWebKitProcess
            && Self.engineDecision(for: request.descriptor, options: request.options, hosting: chromium).engine == .webKit
            ? processGroups : nil
        let host = Self.hostConfiguration(handler: handler, documentAttributes: request.documentAttributes,
                                          options: request.options, dataStore: groups?.dataStore)
        self.init(descriptor: request.descriptor, configuration: host.configuration,
                  inputReadiness: host.inputReadiness, routes: request.routes, route: request.route,
                  options: request.options, surface: request.surface, dynamicResources: request.dynamicResources,
                  pooled: false, load: true, openRequested: requested, chromium: chromium,
                  openPanel: openPanel, registry: registry, processGroups: groups, startsAtFirstShow: startsAtFirstShow,
                  deadlines: deadlines,
                  chatOpen: request.chatOpen)
        // Before the page's Chromium start reads it: that start runs in a later turn (``startChromium(hosting:)``).
        chromiumWindow = request.chromiumWindow
    }
}
