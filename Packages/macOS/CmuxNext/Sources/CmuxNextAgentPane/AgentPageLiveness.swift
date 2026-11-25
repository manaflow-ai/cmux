import AppKit
import CmuxNextPages
public import CmuxNextSettings
import os

/// Every agent page its maker made and nobody closed yet, so one owner can check that each has a reason to live.
///
/// A page draws and runs script for as long as it is in a window and not hidden: Chromium keeps a page that is
/// told it is visible drawing, wherever its view is, and WebKit renders every view in a window. A page whose tab
/// closed must leave that state at once or be closed. Two pages of Leo's NIGHTLY (2026-11-18) still reported
/// visible with no tab and kept the shared renderer busy. The app's tab store, which makes every agent page, asks
/// each owner which pages it holds (``AgentPageRole``) and counts the rest (``AgentPageCensus``): a page no owner
/// holds is an orphan, and ``sweep(owner:retire:)`` closes it once it is out of sight.
@MainActor
public final class AgentPageLiveness {
    private let live = NSHashTable<AgentPaneView>.weakObjects()

    public init() {}

    /// Registers a page its maker just made.
    public func made(_ view: AgentPaneView) { live.add(view) }

    /// Every page made here and not closed, in no particular order.
    public var pages: [AgentPaneView] { live.allObjects.filter { !$0.model.pageClosed } }

    /// Every live page with the owner `owner` names for it; nil there makes it an orphan.
    public func roles(owner: (AgentPaneView) -> AgentPageRole?) -> [(view: AgentPaneView, role: AgentPageRole)] {
        pages.map { ($0, owner($0) ?? .orphan) }
    }

    /// Closes (through `retire`) every orphan that does not show: out of any window, hidden, or parked off screen.
    /// One a pane still shows stays, since closing it would blank the pane, and is only logged; the census counts
    /// it. Returns how many it closed.
    @discardableResult
    public func sweep(owner: (AgentPaneView) -> AgentPageRole?, retire: (AgentPaneView) -> Void) -> Int {
        var closed = 0
        for (view, role) in roles(owner: owner) where role == .orphan {
            guard !view.showsInAPane else {
                Self.log.error("agent page with no owner still shows (session \(view.model.sessionId ?? "-", privacy: .public))")
                continue
            }
            Self.log.error("closing an agent page no tab or owner holds (session \(view.model.sessionId ?? "-", privacy: .public), drawing \(view.drawsForEngine, privacy: .public))")
            retire(view)
            closed += 1
        }
        return closed
    }

    /// `debug.agent_pages`: each live page's owner, whether its engine draws it and whether it is in a window, the
    /// counts by owner, `visible_tabless` and `violations` (``AgentPageCensus``), and `swept` (pages a sweep before
    /// the report closed).
    public func report(owner: (AgentPaneView) -> AgentPageRole?, swept: Int) -> JSONValue {
        let roles = roles(owner: owner)
        let census = AgentPageCensus(roles)
        var counts: [String: JSONValue] = [:]
        for role in AgentPageRole.allCases {
            counts[role.rawValue] = .object(["live": .number(Double(census.count(role))), "visible": .number(Double(census.visible(role)))])
        }
        return .object([
            "pages": .array(roles.map { entry in
                .object([
                    "role": .string(entry.role.rawValue), "visible": .bool(entry.view.drawsForEngine),
                    "in_window": .bool(entry.view.window != nil), "hidden": .bool(entry.view.isHiddenOrHasHiddenAncestor),
                    "chromium": .bool(entry.view.page?.chromiumReportedVisible != nil),
                    "session": entry.view.model.sessionId.map(JSONValue.string) ?? .null,
                ])
            }),
            "by_role": .object(counts),
            "visible_tabless": .number(Double(census.visibleTabless)),
            "violations": .number(Double(census.violations)),
            "swept": .number(Double(swept)),
        ])
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-page-liveness")
}

/// Why a live agent page lives: the one owner that holds it.
public enum AgentPageRole: String, CaseIterable, Sendable {
    /// A tab's page (the app's tab store, keyed by tab).
    case tab
    /// The New Tab pool's prewarmed page.
    case spare
    /// A closed New Tab page waiting in the pool's parking for its tab's release (``AgentPaneSpareReturns``).
    case returning
    /// A closed chat kept whole for Reopen Closed (``AgentPageRetirer``, at most two, 30 s each).
    case kept
    /// A closed page on its way to its teardown (``AgentPageRetirer``).
    case retiring
    /// A chat outside any pane that its caller owns and closes (onboarding's first task, Start Agent's panel).
    case standalone
    /// No owner holds it: nothing will ever close it.
    case orphan
}

/// The live agent pages by owner, and the ones that break the rule: every live page has a tab or is held by an
/// owner that bounds it, and none that its owner let go still draws.
public struct AgentPageCensus: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public var role: AgentPageRole
        /// Its engine draws it now (``AgentPaneView/drawsForEngine``).
        public var visible: Bool
        public var inWindow: Bool

        public init(role: AgentPageRole, visible: Bool, inWindow: Bool) {
            self.role = role
            self.visible = visible
            self.inWindow = inWindow
        }
    }

    public var pages: [Page]

    public init(pages: [Page]) { self.pages = pages }

    @MainActor public init(_ roles: [(view: AgentPaneView, role: AgentPageRole)]) {
        pages = roles.map { Page(role: $0.role, visible: $0.view.drawsForEngine, inWindow: $0.view.window != nil) }
    }

    public func count(_ role: AgentPageRole) -> Int { pages.count(where: { $0.role == role }) }
    public func visible(_ role: AgentPageRole) -> Int { pages.count(where: { $0.role == role && $0.visible }) }

    /// Pages with no tab that their engine still draws. A spare, a returning New Tab page and a kept closed chat
    /// may draw while they wait, each bounded by its owner (one spare per app, ``AgentPaneSpareReturns/limit``, two
    /// kept pages for 30 s); a parked one reports hidden once it drew (cmux#43784, `PageWebView+AwayDrawing`). A standalone page shows in
    /// its caller's panel and is not counted.
    public var visibleTabless: Int { pages.count(where: { $0.role != .tab && $0.role != .standalone && $0.visible }) }

    /// The pages that break the rule: an orphan, whatever its state, or a page its owner let go (retiring) that
    /// still draws. Zero on a healthy app: the detector's assertion.
    public var violations: Int { pages.count(where: { $0.role == .orphan || ($0.role == .retiring && $0.visible) }) }
}

extension AgentPaneView {
    /// Whether this page's engine draws it now: a Chromium page as it was last told (``PageWebView/chromiumReportedVisible``),
    /// any other page while it is in a window and not hidden (WebKit renders every such view, off screen or not).
    public var drawsForEngine: Bool {
        if let reported = page?.chromiumReportedVisible { return reported }
        return window != nil && !isHiddenOrHasHiddenAncestor
    }

    /// Whether a person may see this page now: in a window, not hidden, and not parked off screen.
    var showsInAPane: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
            && !sequence(first: self as NSView, next: \.superview).dropFirst().contains { $0 is PageOffscreenParking }
    }
}
