public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import CoreGraphics
import CmuxNextWakeups
import Foundation

/// How a parked document took its last claim (`debug.page`, `debug.page_preload`).
public struct PageClaimOutcome: Sendable, Equatable {
    public enum Path: String, Sendable {
        /// The parked document acknowledged the claim and kept running (no navigation).
        case acknowledged
        /// The document answered that it was not parked (it already ran): reloaded at once.
        case refused
        /// No answer within ``PageWebView/claimAcknowledgementBudget``: reloaded.
        case timedOut
    }

    public var path: Path
    /// From the claim to the acknowledgement or the fallback reload.
    public var milliseconds: Double
}

/// The claim of a page made parked: the pending acknowledgement of its document (one at a time; a
/// newer claim, a new document or close ends it), and the open that claimed it.
@MainActor
final class PageClaimState {
    var generation: UInt64 = 0
    var pending = false
    var start = ContinuousClock.now
    var outcome: PageClaimOutcome?
    /// An open claimed the page. Every later document of the page boots parked too (its script is in
    /// the page's configuration on both engines), so each one gets the claim again when it loads
    /// (``PageWebView/claimLoadedDocument()``).
    var claimed = false
    /// A claim carried the open's route already. Only the first one does: a later document (a
    /// reload, a crash reload) keeps the place it loaded at, which the person may have moved to.
    var routeSent = false
    /// The fallback reload: a person waits on the claimed page (opening Settings), so it is visible work at its due
    /// time (flexible), never held for a hidden node.
    let deadline: MainDeadline
    var budget: Duration = PageWebView.claimAcknowledgementBudget

    /// - Parameter deadlines: The page's deadline scheduler (``PageWebView/deadlines``).
    init(deadlines: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: "PageWebView.claim", workClass: .visible, alignment: .flexible, scheduler: deadlines)
    }

    /// Ends the pending claim; true when it was pending.
    func end() -> Bool {
        generation &+= 1
        deadline.cancel()
        defer { pending = false }
        return pending
    }
}

/// Claiming a preloaded page's document without a reload (cx-5vg7).
///
/// A page the preload slot (``PagePreloadSlot``) holds was opened parked (``PageOpenRequest/parked``):
/// a document-start script sets `__cmuxPageParked`, and the shared page client
/// (webviews/src/pages/shared/pageClient.ts) holds every call and subscription, so the preload
/// never reads through its empty router and never shows a failed read. The open that claims it binds
/// its routes (``bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``), then calls
/// `cmux.page.claim {route}` on the document: the client shows the route, sends what it held and
/// acknowledges. Only the first claim carries the route; a later document's claim has none, so a
/// reload keeps the place the person moved to, as a cold page's reload does. Only when the document refuses (it already ran) or does not answer within
/// ``claimAcknowledgementBudget`` does the page reload it. Both engines take the same calls: the
/// parked script reaches a Chromium page with the page's other document scripts.
extension PageWebView {
    /// The fallback deadline for the claim acknowledgement: 50 ms, three 60 Hz frames. The
    /// acknowledgement is one script evaluation and one reply message, but it waits for the main
    /// thread to finish the claim's turn (the new window, the tab): 3-11 ms in the harness
    /// (the retired PageHostPool claim benchmark, build host at load 54), 16 ms and more than 20 ms in a live
    /// app when a second and an incognito window opened Settings. A one-frame budget (20 ms was
    /// tried) reloaded the incognito claim, and a false reload costs 50-500 ms, far more than the
    /// 30 extra milliseconds a silent document now waits before its reload.
    public static let claimAcknowledgementBudget: Duration = .milliseconds(50)

    static let claimOp = "cmux.page.claim"
    static let parkedScript = "globalThis.__cmuxPageParked = true;"

    /// How the last claim of this page went; nil before the first claim.
    public var lastClaim: PageClaimOutcome? { claimState.outcome }

    /// Whether an open claimed this page made parked (its routes are bound).
    public var isClaimed: Bool { claimState.claimed }

    /// Binds a page made parked to the open that took it from the preload slot, in the open's turn:
    /// its routes, route, theme surface and dynamic resources, then the claim of its document (at
    /// once when it has loaded, else at its load). A page parked across a change of the served web
    /// files (``bundleStale``) reloads from the new files instead and is claimed at that load. Only the
    /// first call binds; a page not made parked is left as it is.
    ///
    /// - Parameters:
    ///   - routes: The open's op routes.
    ///   - route: The place the page shows (`#/settings/<section>`); nil: its default place.
    ///   - documentAttributes: `data-*` attributes of `<html>` the open sets.
    ///   - surface: The theme surface (``themeSurface``).
    ///   - dynamicResources: Answers the descriptor's dynamic prefixes.
    package func bindClaim(routes: [PageRoute], route: String?, documentAttributes: [String: String] = [:],
                           surface: SurfaceKind? = nil, dynamicResources: (any PageDynamicResourceSource)? = nil) {
        guard isPooled, !claimState.claimed else { return }
        traceOpenRequested(.claim)
        router.rebind(descriptor: descriptor, routes: routes)
        self.dynamicResources = dynamicResources
        themeSurface = surface
        self.route = route.map { $0.hasPrefix("#") ? $0 : "#" + $0 }
        // Live attributes: set on this document at its claim and again on every later one.
        for (name, value) in documentAttributes { liveDocumentAttributes[name] = value }
        claimState.claimed = true
        // Parked before the served web files changed (``bundleStale``), it holds the old build: the claim
        // loads the files served now, and that document boots parked and gets the claim at its load.
        if bundleStale { return reloadForBundle() }
        // A document still loading boots parked and gets the claim at its load (``claimLoadedDocument()``).
        guard loaded else { return }
        // Its parked frame was the parking's size: shown at once in another pane size, it drew its
        // old layout, then blank tiles while it laid out again. The pane keeps what it showed until
        // the page drew at the pane's size (PanePaintHold).
        paintedUptime = nil
        repaintsAtNextLayout = true
        needsLayout = true
        sendClaim(reloadsUnanswered: true)
    }

    /// A new document of a claimed page loaded (its first one after a claim made while it loaded, a
    /// reload, a crash reload): it booted parked, so it gets the claim now. It is a fresh parked
    /// document, so it is never reloaded for a refusal or silence (a reload would boot parked again).
    func claimLoadedDocument() {
        guard claimState.claimed, !claimState.pending else { return }
        sendClaim(reloadsUnanswered: false)
    }

    /// Hands the claim to the current document, with its live attributes (the open's among them) and theme.
    private func sendClaim(reloadsUnanswered: Bool) {
        _ = claimState.end()
        let state = claimState
        let generation = state.generation
        state.pending = true
        state.start = .now
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        let claimRoute = state.routeSent ? nil : self.route
        state.routeSent = true
        let params: JSONValue = claimRoute.map { ["route": .string($0)] } ?? .object([:])
        let router = router
        // task-owner: one claim reply; ends with the document's answer or the page's close
        // main-hop-allow: callPage is the router's main-actor async page call (the claim runs in the page); the task only records its answer
        Task { @MainActor [weak self] in
            let path: PageClaimOutcome.Path
            do {
                let reply = try await router.callPage(Self.claimOp, params: params)
                path = reply["claimed"]?.boolValue == true ? .acknowledged : .refused
            } catch {
                path = .refused
            }
            self?.finishClaim(generation, path, reloads: reloadsUnanswered)
        }
        guard reloadsUnanswered else { return }
        state.deadline.schedule(after: state.budget) { [weak self] in
            self?.finishClaim(generation, .timedOut, reloads: true)
        }
    }

    private func finishClaim(_ generation: UInt64, _ path: PageClaimOutcome.Path, reloads: Bool) {
        let state = claimState
        guard state.generation == generation, state.end() else { return }
        let (seconds, attoseconds) = (ContinuousClock.now - state.start).components
        state.outcome = PageClaimOutcome(path: path,
                                         milliseconds: Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
        guard path != .acknowledged, reloads else {
            if repaintsAtNextLayout { needsLayout = true }
            resumeLoadWaiters()
            return
        }
        // The reloaded document reports its own first paint, and gets the claim at its load.
        repaintsAtNextLayout = false
        loaded = false
        reloadDocument()
    }

    /// Loads the current page URL again, in whichever engine shows it (a plain load of the same URL
    /// with another fragment is only a fragment navigation, so this reloads from script). The open that
    /// claimed the page waits on it, so a frozen page thaws first (``PageFrozenPush/thawsFirst``).
    func reloadDocument() {
        traceOpenLoadStarted(.reload)
        let fragment = route ?? "/"
        evaluate("history.replaceState(null, \"\", \(JSONValue.string(fragment).compactText)); location.reload();",
                 whileFrozen: .thawsFirst)
    }
}

/// A cmux page in the preload slot (p13-webui.md 3.D), on either engine: hidden is the view's own
/// hidden state, which both engines take their visibility from (WebKit itself, Chromium through
/// ``setEngineVisible(_:)``), and freeze and thaw are the page lifecycle's (``freezePage()``).
extension PageWebView: PreloadablePage {
    public var preloadView: NSView { self }

    public var preloadTraceID: UInt64 { traceID }

    /// The document's first paint (``PagePaintProbe``) for a page that has not painted, else the next
    /// frame it draws (``afterNextFrame(_:)``).
    public func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {
        if hasPainted { afterNextFrame { body() } } else { whenPainted { body() } }
    }

    /// WebKit's picture of the page. A Chromium picture is a JPEG with no alpha
    /// (``snapshotKeepsClearAreas``): a page's clear areas would cover the tab black, so it has none.
    public func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {
        guard snapshotKeepsClearAreas else { return body(nil) }
        // task-owner: one picture of the parked page; ends with WebKit's answer
        // main-hop-allow: snapshot() is the page's main-actor async picture (WebKit's capture); the task only hands its image on
        Task { @MainActor [weak self] in
            let image = await self?.snapshot()
            body(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    public func preloadSetVisible(_ visible: Bool) {
        isHidden = !visible
    }

    public func preloadFreeze() -> Bool {
        freezePage()
    }

    public func preloadThaw() {
        thawPage()
    }
}
