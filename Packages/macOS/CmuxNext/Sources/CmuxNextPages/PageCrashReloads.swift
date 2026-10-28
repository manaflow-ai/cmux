public import Foundation

/// The renderer process a page's document runs in, as its engine names it. Chrome tells one renderer
/// death from another by its `RenderProcessHost` (`RenderProcessHostObserver::RenderProcessExited` runs
/// once per host, content/public/browser/render_process_host_observer.h), never by when pages report it.
public nonisolated enum PageRendererID: Hashable, Sendable {
    /// A WebKit WebContent process (`_webProcessIdentifier`).
    case webKit(pid: Int32)
    /// A Chromium renderer (its `--renderer-client-id`, the `RenderProcessHost` id: never reused in a run).
    case chromium(client: Int32)
}

/// Decides whether a page reloads after its web content process crashes (every page on the page
/// host, and the old agent pane host until it is deleted). A page that crashes as it loads would
/// otherwise reload forever.
///
/// One budget can serve the pages that share a renderer (``PageCrashGroups``): each page the renderer
/// ran reports its death under the renderer's ``PageRendererID``, and one death counts once, however far
/// apart the reports come. A report with no renderer (the page crashed before a document committed)
/// is a death of its own.
public nonisolated struct PageCrashReloads: Equatable, Sendable {
    /// Reloads allowed within ``window``. The window is long because one
    /// load-to-crash cycle can take 20 seconds or more (the handshake waits
    /// for acpmux), and a slow crash loop must stop too.
    public static let limit = 3
    public static let window: TimeInterval = 600

    /// A counted renderer death and the answer it got.
    nonisolated private struct Death: Equatable, Sendable {
        let at: Date
        let reloads: Bool
    }

    private var crashes: [Date] = []
    private var deaths: [PageRendererID: Death] = [:]

    public init() {}

    /// Records a crash at `now`; true when the page should reload.
    ///
    /// - Parameters:
    ///   - now: When the crash was reported.
    ///   - renderer: The renderer that died. A death counted before within ``window`` is not counted
    ///     again: its other pages get the answer it got. Nil counts every report.
    public mutating func shouldReload(at now: Date, renderer: PageRendererID? = nil) -> Bool {
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window }
        deaths = deaths.filter { now.timeIntervalSince($0.value.at) < Self.window }
        if let renderer, let death = deaths[renderer] { return death.reloads }
        crashes.append(now)
        let reloads = crashes.count <= Self.limit
        if let renderer { deaths[renderer] = Death(at: now, reloads: reloads) }
        return reloads
    }

    /// A document committed in `renderer`: that process lives, so a later death under its id is another
    /// process's (WebKit's id is a pid, which the system can reuse).
    public mutating func rendererCommitted(_ renderer: PageRendererID) {
        deaths[renderer] = nil
    }

    /// Whether a reload at `now` stays within the budget: false once more than ``limit`` crashes
    /// were counted within ``window``. Records nothing.
    public func allowsReload(at now: Date) -> Bool {
        crashes.count(where: { now.timeIntervalSince($0) < Self.window }) <= Self.limit
    }
}

/// The crash budgets of a ``WebUIHost``'s pages (plans/cmux-next/chrome-parity/p13-webui.md 3.C: "the
/// crash budget (3 per 600 s) is per group"). Pages share a budget only when they really share a
/// renderer: a WebKit page in the host's ``WebProcessGroups``, or a Chromium page of a sharing
/// ``PageProcessGroup`` while Chromium groups renderers (``chromiumSharesByGroup``). A renderer that
/// keeps dying then stops every page of its group from loading into it again, and one death that takes
/// 5 pages counts once. Every other page has a budget of its own.
@MainActor
package final class PageCrashGroups {
    /// The engine whose renderers a budget's pages share; WebKit and Chromium never share one.
    nonisolated package enum Engine: Hashable, Sendable {
        case webKit
        case chromium
    }

    /// Whose budget a crash counts against.
    nonisolated package enum Key: Hashable, Sendable {
        /// The pages of one group that share renderers of one engine.
        case group(Engine, PageProcessGroup)
        /// One page alone.
        case page(ObjectIdentifier)
    }

    /// Whether Chromium puts the pages of a sharing group in one renderer (the `pageProcessGroups`
    /// feature, which names each page's group in Chromium's scheme table, CmuxNextApp `FirstPartyPageSchemes`).
    package let chromiumSharesByGroup: Bool
    /// The renderer a page's document runs in now; nil when its engine does not say.
    let rendererID: @MainActor (PageWebView) -> PageRendererID?
    private var budgets: [Key: PageCrashReloads] = [:]

    /// - Parameters:
    ///   - chromiumSharesByGroup: The `pageProcessGroups` feature.
    ///   - rendererID: Reads a page's renderer (the app: WebKit's `_webProcessIdentifier`, the CEF tab's
    ///     renderer client); a test passes its own. The default knows none, so no two reports merge.
    package init(chromiumSharesByGroup: Bool = false,
                 rendererID: @escaping @MainActor (PageWebView) -> PageRendererID? = { _ in nil }) {
        self.chromiumSharesByGroup = chromiumSharesByGroup
        self.rendererID = rendererID
    }

    /// Records that a page of `key` lost `renderer` at `now`; true when it may reload.
    package func recordCrash(_ key: Key, renderer: PageRendererID?, at now: Date) -> Bool {
        budgets[key, default: PageCrashReloads()].shouldReload(at: now, renderer: renderer)
    }

    /// A page of `key` committed a document in `renderer` (``PageCrashReloads/rendererCommitted(_:)``).
    package func rendererCommitted(_ renderer: PageRendererID, in key: Key) {
        budgets[key]?.rendererCommitted(renderer)
    }

    /// Whether a page of `key` may reload at `now` (a page that crashed hidden, as it shows).
    package func allowsReload(_ key: Key, at now: Date) -> Bool {
        budgets[key]?.allowsReload(at: now) ?? true
    }

    /// The person asked to reload a page of `key` (the crash notice's Reload): its crashes are forgotten.
    package func forgive(_ key: Key) {
        budgets[key] = nil
    }

    /// `page` closed: the budget only it used goes.
    package func forget(_ page: ObjectIdentifier) {
        budgets[.page(page)] = nil
    }
}
