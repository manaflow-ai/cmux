public import Foundation
import os

/// Decides whether a page reloads after its web content process crashes (every page on the page
/// host, and the old agent pane host until it is deleted). A page that crashes as it loads would
/// otherwise reload forever.
///
/// One budget can serve the pages of one renderer group (``PageCrashGroups``): the pages a renderer
/// ran each report its death, within ``sameCrash`` of each other, and that counts as one crash. A page
/// never shares a crash with itself, so one page's crash loop counts every crash.
public nonisolated struct PageCrashReloads: Equatable, Sendable {
    /// Reloads allowed within ``window``. The window is long because one
    /// load-to-crash cycle can take 20 seconds or more (the handshake waits
    /// for acpmux), and a slow crash loop must stop too.
    public static let limit = 3
    public static let window: TimeInterval = 600
    /// How soon after a counted crash the other pages of its renderer report the same death. The
    /// engines report each page of a dead renderer in one burst of callbacks.
    public static let sameCrash: TimeInterval = 2

    /// The last counted crash and the pages that reported it.
    nonisolated private struct Burst: Equatable, Sendable {
        let at: Date
        var pages: Set<ObjectIdentifier>
        let reloads: Bool
    }

    private var crashes: [Date] = []
    private var burst: Burst?

    public init() {}

    /// Records a crash at `now`; true when the page should reload.
    ///
    /// - Parameters:
    ///   - now: When the crash was reported.
    ///   - page: The page that reported it, for a budget its renderer group shares: another page's
    ///     report within ``sameCrash`` of a counted crash is that crash and gets its answer. Nil
    ///     counts every report (a budget of one page).
    public mutating func shouldReload(at now: Date, page: ObjectIdentifier? = nil) -> Bool {
        if let page, var burst, !burst.pages.contains(page), now.timeIntervalSince(burst.at) < Self.sameCrash {
            burst.pages.insert(page)
            self.burst = burst
            return burst.reloads
        }
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window }
        crashes.append(now)
        let reloads = crashes.count <= Self.limit
        burst = page.map { Burst(at: now, pages: [$0], reloads: reloads) }
        return reloads
    }

    /// Whether a reload at `now` stays within the budget: false once more than ``limit`` crashes
    /// were counted within ``window``. Records nothing.
    public func allowsReload(at now: Date) -> Bool {
        crashes.count(where: { now.timeIntervalSince($0) < Self.window }) <= Self.limit
    }
}

/// The crash budgets of a ``WebUIHost``'s pages, one per renderer group (plans/cmux-next/chrome-parity/
/// p13-webui.md 3.C: "the crash budget (3 per 600 s) is per group"). The pages of a group that
/// shares a renderer (``PageProcessGroup/sharesRenderer``) share one ``PageCrashReloads``, so a
/// renderer that keeps dying stops every page of its group from loading into it again, and one death
/// that takes 5 pages counts once. A `solo` or `secrets` page runs alone and has a budget of its own.
@MainActor
package final class PageCrashGroups {
    nonisolated private enum Key: Hashable {
        case group(PageProcessGroup)
        case page(ObjectIdentifier)
    }

    private var budgets: [Key: PageCrashReloads] = [:]

    package init() {}

    /// Records that `page`, of `group`, lost its renderer at `now`; true when it may reload.
    package func recordCrash(of page: ObjectIdentifier, in group: PageProcessGroup, at now: Date) -> Bool {
        budgets[Self.key(page, group), default: PageCrashReloads()].shouldReload(at: now, page: page)
    }

    /// Whether `page`, of `group`, may reload at `now` (a page that crashed hidden, as it shows).
    package func allowsReload(of page: ObjectIdentifier, in group: PageProcessGroup, at now: Date) -> Bool {
        budgets[Self.key(page, group)]?.allowsReload(at: now) ?? true
    }

    /// The person asked to reload `page` (the crash notice's Reload): its group's crashes are forgotten.
    package func forgive(_ page: ObjectIdentifier, in group: PageProcessGroup) {
        budgets[Self.key(page, group)] = nil
    }

    /// `page` closed: the budget only it used goes.
    package func forget(_ page: ObjectIdentifier) {
        budgets[.page(page)] = nil
    }

    private static func key(_ page: ObjectIdentifier, _ group: PageProcessGroup) -> Key {
        group.sharesRenderer ? .group(group) : .page(page)
    }
}

/// What a ``PageWebView`` does when its renderer dies (p13-webui.md 3.C): a shown page reloads at once,
/// a hidden one is marked to reload when it shows, and none reloads once its budget ran out (its host
/// shows the crash notice). Chrome does the same for a background tab: `NavigationControllerImpl::
/// SetNeedsReload` marks it and `LoadIfNecessary` reloads it once `WebContentsImpl::WasShown` makes the
/// controller active (content/browser/renderer_host/navigation_controller_impl.cc), so a renderer that
/// held one shown page and four hidden ones costs one load, not five.
///
/// A page waits for its show only in ``groups`` (the ``WebUIHost`` sets it while the page lifecycle,
/// the one visibility source, is on); otherwise it keeps its own budget and reloads at once, hidden or not.
@MainActor
package final class PageCrashRecovery {
    /// The crash budgets of the page's host, one per renderer group; nil: the page's own budget.
    var groups: PageCrashGroups?
    private var own = PageCrashReloads()
    /// Its renderer died while it was hidden: it reloads when it shows.
    package private(set) var needsReload = false
    /// How many times the page was reloaded after a crash (tests, the crash bench).
    package private(set) var reloads = 0
    /// What the page's engine was last told (``PageWebView/setEngineVisible(_:)``, from its view's
    /// window and hidden state): whether a person can see the page.
    private var shown = false

    package init() {}

    /// `page`'s renderer died (``PageWebView/contentProcessTerminated()``, after its document's state
    /// was reset): it reloads now, waits for its show, or stops; its host hears it (``PageWebView/onCrash``).
    func crashed(_ page: PageWebView) {
        let now = page.now()
        let reloading = groups?.recordCrash(of: ObjectIdentifier(page), in: page.descriptor.processGroup, at: now)
            ?? own.shouldReload(at: now)
        needsReload = reloading && groups != nil && !shown
        if reloading, !needsReload {
            reload(page)
        } else {
            page.loadState.set(loading: false, page: page) // no load follows now
            if !reloading { Self.logStop(page) }
        }
        page.onCrash?(page, reloading)
    }

    /// `page`'s engine is told it shows or hides (``PageWebView/setEngineVisible(_:)``). A page whose
    /// renderer died while it was hidden reloads as it shows, unless its group crashed past its budget
    /// since; then its host hears that it stopped, and shows the crash notice.
    func engineVisibilityChanged(_ visible: Bool, page: PageWebView) {
        shown = visible
        guard visible, needsReload else { return }
        needsReload = false
        guard groups?.allowsReload(of: ObjectIdentifier(page), in: page.descriptor.processGroup, at: page.now()) ?? true else {
            Self.logStop(page)
            page.onCrash?(page, false)
            return
        }
        page.loadState.set(loading: true, page: page)
        reload(page)
    }

    /// The person reloads `page` from its crash notice: the crashes counted against it, and against
    /// its group, are forgotten.
    func forgive(_ page: PageWebView) {
        own = PageCrashReloads()
        needsReload = false
        groups?.forgive(ObjectIdentifier(page), in: page.descriptor.processGroup)
    }

    private func reload(_ page: PageWebView) {
        reloads += 1
        page.reloadPage()
    }

    private static func logStop(_ page: PageWebView) {
        page.logger.error("page \(page.descriptor.id, privacy: .public) keeps crashing; not reloaded")
    }
}
