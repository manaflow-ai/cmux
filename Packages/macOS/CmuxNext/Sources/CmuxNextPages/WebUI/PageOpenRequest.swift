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
    /// The page loads now, parked, for the preload slot (``PagePreloadSlot``): its document holds
    /// every call and subscription until an open claims it with its routes
    /// (``PageWebView/bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``), and it
    /// never waits for a first show. Its `routes` and `dynamicResources` are those of the claim.
    public var parked: Bool
    /// The agent chat open the page shows (``PageWebView/chatOpen``), known before its document starts.
    public var chatOpen: ChatOpenStages?
    /// The pane window a Chromium page joins (``PageWebView/chromiumWindow``); nil gives it one of its
    /// own. The pane that shows a page tab sets it when it shows the tab, so an opener may leave it nil.
    public var chromiumWindow: PageChromiumWindow?
    /// Who asks for the page: a person (the default) or automation start its Chromium page at once; the launch's
    /// restore (``PageOpenOrigin/launchRestore``) follows the launch order.
    public var origin: PageOpenOrigin

    public init(descriptor: PageDescriptor, root: URL? = nil, routes: [PageRoute], route: String? = nil,
                documentAttributes: [String: String] = [:], options: PageEngineOptions = .standard,
                surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil,
                parked: Bool = false, chatOpen: ChatOpenStages? = nil, chromiumWindow: PageChromiumWindow? = nil,
                origin: PageOpenOrigin = .user) {
        self.descriptor = descriptor
        self.root = root
        self.routes = routes
        self.route = route
        self.documentAttributes = documentAttributes
        self.options = options
        self.surface = surface
        self.dynamicResources = dynamicResources
        self.parked = parked
        self.chatOpen = chatOpen
        self.chromiumWindow = chromiumWindow
        self.origin = origin
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
    ///   - processGroups: The host's shared WebKit processes; a page joins its group there when it
    ///     shows in WebKit (``WebProcessGroups/membership(of:options:)``). Nil: a process of its own.
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
        let parkedOwner = request.parked ? PagePooledOwner() : nil
        let handler = parkedOwner.map { Self.parkedSchemeHandler(page: request.descriptor, root: root, owner: $0) }
            ?? PageSchemeHandler(page: request.descriptor, root: root, dynamicSource: request.dynamicResources)
        // Only a page WebKit shows joins: a Chromium page has no WebKit process to share.
        // A parked page joins its group as a cold open of it does: the slot never retargets it to another page.
        let showsInWebKit = Self.engineDecision(for: request.descriptor, options: request.options, hosting: chromium).engine == .webKit
        let group = showsInWebKit ? processGroups.flatMap { groups in
            groups.membership(of: request.descriptor, options: request.options)
                .map { PageWebKitProcessGroup(groups: groups, membership: $0) }
        } : nil
        let host = Self.hostConfiguration(handler: handler, documentAttributes: request.documentAttributes,
                                          options: request.options, dataStore: group.map { $0.groups.dataStore(for: $0.membership) })
        if request.parked { Self.installParkedScript(host.configuration.userContentController) }
        self.init(descriptor: request.descriptor, configuration: host.configuration,
                  inputReadiness: host.inputReadiness, routes: request.routes, route: request.route,
                  options: request.options, surface: request.surface, dynamicResources: request.dynamicResources,
                  pooled: request.parked, load: true, openRequested: requested, chromium: chromium,
                  openPanel: openPanel, registry: registry, processGroup: group,
                  startsAtFirstShow: startsAtFirstShow && !request.parked, deadlines: deadlines,
                  chatOpen: request.chatOpen, origin: request.origin)
        if let parkedOwner {
            parkedOwner.view = self
            pooledOwner = parkedOwner
        }
        // Its crashes count against its group's budget: the group's pages die together (PageCrashRecovery).
        crash.sharesWebKitProcess = group != nil
        // Before the page's Chromium start reads it: that start runs in a later turn (``startChromium(hosting:origin:)``).
        chromiumWindow = request.chromiumWindow
    }
}
