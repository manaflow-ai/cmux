public import AppKit
public import CmuxNextDesign
public import CmuxNextInputCore
public import CmuxNextSettings
public import CmuxNextWakeups

/// Settings, History and Cloud through the app's one preload slot (``WebUIHost/preload``,
/// p13-webui.md 3.D; feature `pagePreload`, default off). It replaces PageHostPool,
/// which built a WebKit Settings host at every launch, even when pages show in Chromium and could
/// never take it.
///
/// Chrome preloads its top-chrome WebUI the same way (chrome/browser/ui/webui/top_chrome/
/// webui_contents_preload_manager.cc): once a WebUI of a kind was shown (`kPreloadOnMakeVisible`),
/// the next one of that kind loads ahead when the browser is idle, at most one in all, and none under
/// memory pressure. Here:
///
/// - An open of Settings, History or Cloud (``claim(_:routes:route:documentAttributes:surface:dynamicResources:)``)
///   names the page to preload next; once input has been quiet for ``idleInput``, the slot loads it
///   parked (``PageOpenRequest/parked``), in the page's own engine, in this coordinator's parking in
///   the target window, at the size of that window's focused pane, with the document attributes a
///   cold open gives it. Nothing preloads at launch.
/// - It preloads only into an empty slot, as `PreloadSelector` decides: a held page
///   is never replaced, so it never evicts New Tab's preload, and New Tab never
///   evicts it. When the slot empties (a claim or a drop), it arms its next page again.
/// - No page preloads while its owner keeps a view that the next open shows again (Settings).
/// - The next open of that page takes it in its own turn and binds its routes to it; the tab content
///   takes the view from the parking in the same turn. An open with other document attributes than
///   the preload booted with drops it and opens cold: the page read them once, when it started.
/// - The slot drops it at any memory pressure but normal (``WebUIHost``'s registration), and this
///   coordinator drops it when its window closes (``windowWillClose(_:)``).
///
/// ```swift
/// let preloads = PagePreloads(webUI: webUI, slot: slot, deadlines: mainDeadlines, input: inputTap,
///                             isEnabled: { features.isEnabled(.pagePreload) }, target: { activeTarget() })
/// let page = preloads.claim(.settings, routes: routes, route: route) ?? webUI.open(request)
/// ```
@MainActor
public final class PagePreloads {
    /// A page that preloads, and its key in the slot.
    public enum Page: String, CaseIterable, Sendable {
        case settings, history, cloud

        /// Its key in the preload slot.
        public var key: PagePreloadSlot.Key { PagePreloadSlot.Key("page.\(rawValue)") }

        /// The page.
        public var descriptor: PageDescriptor {
            switch self {
            case .settings: .settings
            case .history: .history
            case .cloud: .cloud
            }
        }

        /// The engine options its opens use, the preload's and a cold open's alike.
        public var options: PageEngineOptions { .standard }

        /// The theme surface its open gives it.
        public var surface: SurfaceKind? { self == .settings ? .settings : nil }

        /// The `data-*` attributes of `<html>` its opens give it now, the preload's and a cold open's
        /// alike: Cloud's machine list layout (webviews/src/pages/cloud/main.tsx reads it once, at mount).
        public var documentAttributes: [String: String] {
            self == .cloud ? ["cloud-machines-layout": PageTunables.cloudMachinesLayout.value.rawValue] : [:]
        }
    }

    /// Where a preload waits: the window content its parking goes in, and the size the page will
    /// show at (the focused pane's content).
    public typealias Target = (content: NSView, size: NSSize)

    /// How long input stays quiet before a preload starts: the selector's 750 ms (p13-webui.md 3.D).
    public static let idleInput: Duration = .milliseconds(750)
    /// The input that pushes a waiting preload back: key-downs, clicks and scrolls.
    static let delayingInput: InputEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]

    private let slot: PagePreloadSlot
    private let input: any InputObserving
    private let isEnabledNow: @MainActor () -> Bool
    private let target: @MainActor () -> Target?
    private let attributes: @MainActor (Page) -> [String: String]
    private let keepsView: @MainActor (Page) -> Bool
    private let open: @MainActor (PageOpenRequest) -> PageWebView?
    private let parking = PagePreloadParkingView(frame: .zero)
    /// The quiet-input deadline of the next preload: work nobody sees, so the background class.
    private let deadline: MainDeadline
    private var inputSubscription: InputSubscription?
    private var started = false
    /// The page opened last: the one that preloads next. Nil until an open.
    public private(set) var next: Page?
    /// The document attributes the held page booted with.
    private var heldAttributes: [String: String] = [:]
    /// The page the last claim took (`debug.page_preload`'s claim outcome).
    public private(set) weak var lastClaimed: PageWebView?

    /// - Parameters:
    ///   - webUI: The app's one page owner, which opens the preloads.
    ///   - slot: The app's one preload slot (``WebUIHost/preload``), made in one place by the composition root.
    ///   - deadlines: The app's deadline scheduler (the quiet-input deadline's).
    ///   - input: The app's input tap: a waiting preload observes its key-downs, clicks and scrolls.
    ///   - isEnabled: Whether pages preload now (feature `pagePreload`).
    ///   - target: The active window's content and its focused pane's content size; nil: no window.
    ///   - documentAttributes: The attributes a page's open gives it now (default: ``Page/documentAttributes``).
    ///   - keepsView: Whether the next open of a page shows a view its owner keeps (the Settings page
    ///     `SettingsWindowService` keeps): a preload of it would wait unclaimed.
    ///   - open: Opens a preload's page (nil: `webUI`'s ``WebUIHost/open(_:)``; a test serves a page of its own).
    public init(webUI: WebUIHost, slot: PagePreloadSlot, deadlines: MainDeadlineScheduler, input: any InputObserving,
                isEnabled: @escaping @MainActor () -> Bool, target: @escaping @MainActor () -> Target?,
                documentAttributes: @escaping @MainActor (Page) -> [String: String] = { $0.documentAttributes },
                keepsView: @escaping @MainActor (Page) -> Bool = { _ in false },
                open: (@MainActor (PageOpenRequest) -> PageWebView?)? = nil) {
        self.slot = slot
        self.input = input
        isEnabledNow = isEnabled
        self.target = target
        attributes = documentAttributes
        self.keepsView = keepsView
        self.open = open ?? { [weak webUI] request in webUI?.open(request) }
        deadline = MainDeadline(owner: "webui.preload.page", workClass: .background, scheduler: deadlines)
        slot.observeEmptied { [weak self] _ in self?.schedule() }
    }

    /// Whether pages preload (feature `pagePreload`).
    public var isEnabled: Bool { isEnabledNow() }

    /// The page the slot holds now, when it is one of these pages.
    public var heldPage: PageWebView? {
        guard parking.superview != nil, let key = slot.key, Page.allCases.contains(where: { $0.key == key }) else { return nil }
        return slot.page as? PageWebView
    }

    /// The launch painted (`AppServices+AfterFirstFrame`): preloads may start from now on, after
    /// an open names one.
    public func start() {
        started = true
        schedule()
    }

    /// The open of `page`: the slot's preload of it, claimed in this turn with the open's routes, or
    /// nil (the open makes its page cold). Either way `page` preloads next, once input is quiet.
    ///
    /// The claimed view stays in the parking, hidden to the person, until the tab content adds it in
    /// this same turn.
    ///
    /// - Parameters:
    ///   - page: The page the open shows.
    ///   - routes: Its op routes.
    ///   - route: The place it opens at.
    ///   - documentAttributes: `data-*` attributes of its `<html>`; a preload that booted with others is dropped.
    ///   - surface: Its theme surface.
    ///   - dynamicResources: Answers its dynamic prefixes.
    /// - Returns: The page, bound to the open.
    public func claim(_ page: Page, routes: [PageRoute], route: String? = nil, documentAttributes: [String: String] = [:],
                      surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil) -> PageWebView? {
        guard isEnabled else { return nil }
        defer { noteOpened(page) }
        guard slot.key == page.key else { return nil }
        guard heldAttributes == documentAttributes else {
            slot.drop()
            return nil
        }
        // At the size the tab will show it at (the focused pane's): a page parked at another size has no cover.
        let frame = NSRect(origin: .zero, size: target()?.size ?? parking.bounds.size)
        guard let claim = slot.claim(page.key, into: parking, frame: frame) else { return nil }
        guard let view = claim.page as? PageWebView else {
            claim.page.preloadView.removeFromSuperview()
            claim.page.close()
            return nil
        }
        view.bindClaim(routes: routes, route: route, documentAttributes: documentAttributes, surface: surface,
                       dynamicResources: dynamicResources)
        lastClaimed = view
        return view
    }

    /// `window` is closing: a page waiting in it goes (it would keep its renderer for a closed window).
    public func windowWillClose(_ window: NSWindow?) {
        guard let window, parking.window === window else { return }
        drop()
        parking.removeFromSuperview()
    }

    /// Drops the held page, if it is one of these pages.
    public func drop() {
        if heldPage != nil { slot.drop() }
    }

    // MARK: Preload

    private func noteOpened(_ page: Page) {
        next = page
        schedule()
    }

    /// Whether ``next`` may preload now: the slot is empty (another owner's page keeps it) and takes
    /// pages, and no kept view would show in its place.
    private var mayPreload: Bool {
        guard isEnabled, let next else { return false }
        return slot.count == 0 && slot.allowsPreload && !keepsView(next)
    }

    /// Arms the quiet-input deadline for ``next``; each key, click or scroll pushes it back.
    private func schedule() {
        guard started, mayPreload else { return }
        if inputSubscription == nil {
            inputSubscription = input.observe(types: Self.delayingInput) { [weak self] _ in self?.armDeadline() }
        }
        armDeadline()
    }

    private func armDeadline() {
        deadline.schedule(after: Self.idleInput) { [weak self] in self?.preloadNow() }
    }

    /// Loads ``next`` parked in the target window, at the target size (the window's content size
    /// when the pane has none), with the attributes its open gives it now.
    public func preloadNow() {
        inputSubscription = nil
        guard mayPreload, let next, let target = target() else { return }
        if parking.superview !== target.content {
            target.content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        let size = target.size.width > 0 && target.size.height > 0 ? target.size : target.content.bounds.size
        let documentAttributes = attributes(next)
        let request = PageOpenRequest(descriptor: next.descriptor, routes: [], documentAttributes: documentAttributes,
                                      options: next.options, surface: next.surface, parked: true)
        let open = open
        if slot.preload(next.key, size: size, in: parking, make: { _ in open(request) }) {
            heldAttributes = documentAttributes
        }
    }

    // MARK: debug.page_preload

    /// The `debug.page_preload` report: the slot's held page, its phase and freeze, the last claim
    /// and how its document took the claim. `action`: `drop` drops the held page; `preload` loads
    /// the next page now, without the quiet wait (into an empty slot only).
    public func debugReport(action: String?) -> JSONValue {
        switch action {
        case "drop": drop()
        case "preload": preloadNow()
        default: break
        }
        let held = heldPage
        var report: [String: JSONValue] = [
            "enabled": .bool(isEnabled),
            "next": next.map { .string($0.rawValue) } ?? .null,
            "key": slot.key.map { .string($0.rawValue) } ?? .null,
            "phase": slot.phase.map { .string($0.rawValue) } ?? .null,
            "frozen": .bool(slot.isFrozen),
            "allows_preload": .bool(slot.allowsPreload),
            "engine": held.map { .string($0.showsChromium ? "chromium" : "webkit") } ?? .null,
            "window_number": held?.window.map { .number(Double($0.windowNumber)) } ?? .null,
        ]
        if let claim = slot.lastClaim {
            report["last_claim"] = ["key": .string(claim.key.rawValue), "covered": .bool(claim.covered),
                                    "refit": .bool(claim.refit), "ms": .number(claim.milliseconds)]
        }
        if let outcome = lastClaimed?.lastClaim {
            report["claim_outcome"] = ["path": .string(outcome.path.rawValue), "ms": .number(outcome.milliseconds)]
        }
        return .object(report)
    }
}
