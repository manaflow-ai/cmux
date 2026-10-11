public import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import WebKit

/// How a pooled document took its last claim (`debug.page`, `debug.page_host_pool`).
public struct PageClaimOutcome: Sendable, Equatable {
    public enum Path: String, Sendable {
        /// The parked document acknowledged the claim and kept running (no navigation).
        case acknowledged
        /// The document answered that it was not parked (it already ran): reloaded at once.
        case refused
        /// No answer within ``PageWebView/claimAcknowledgementBudget``: reloaded.
        case timedOut
        /// Another page origin, or a document that had not loaded: a plain load.
        case loaded
    }

    public var path: Path
    /// From the claim to the acknowledgement or the fallback reload.
    public var milliseconds: Double
}

/// The pending claim of a pooled host's document (one at a time; a newer claim, a new document or
/// close ends it).
@MainActor
final class PageClaimState {
    var generation: UInt64 = 0
    var pending = false
    var start = ContinuousClock.now
    var outcome: PageClaimOutcome?
    /// The fallback deadline's clock (tests inject a manual one).
    var clock: any Clock<Duration> = ContinuousClock() {
        didSet { deadline = DemandTimer(owner: "PageWebView.claim", clock: clock) }
    }
    private(set) var deadline = DemandTimer(owner: "PageWebView.claim")
    var budget: Duration = PageWebView.claimAcknowledgementBudget

    /// Ends the pending claim; true when it was pending.
    func end() -> Bool {
        generation &+= 1
        deadline.cancel()
        defer { pending = false }
        return pending
    }
}

/// Claiming the parked spare's document without a reload (cx-5vg7).
///
/// A pooled host loads its document parked: a document-start script sets `__cmuxPageParked`, and
/// the shared page client (webviews/src/pages/shared/pageClient.ts) holds every call and
/// subscription, so the spare never reads through its empty router and never shows a failed read.
/// A claim of the same page binds the claim's routes, then calls `cmux.page.claim {route}` on the
/// document: the client shows the route, sends what it held and acknowledges. Only when the
/// document refuses (it already ran: a released host parked again) or does not answer within
/// ``claimAcknowledgementBudget`` does the host reload it, as every claim did before.
extension PageWebView {
    /// The fallback deadline for the claim acknowledgement: 50 ms, three 60 Hz frames. The
    /// acknowledgement is one script evaluation and one reply message, but it waits for the main
    /// thread to finish the claim's turn (the new window, the tab): 3-11 ms in the harness
    /// (PageHostPoolClaimReadyBenchmark, build host at load 54), 16 ms and more than 20 ms in a
    /// live app when a second and an incognito window opened Settings. A one-frame budget (20 ms
    /// was tried) reloaded the incognito claim, and a false reload costs 50-500 ms, far more than
    /// the 30 extra milliseconds a silent document now waits before its reload.
    public static let claimAcknowledgementBudget: Duration = .milliseconds(50)

    static let claimOp = "cmux.page.claim"
    static let parkedScript = "globalThis.__cmuxPageParked = true;"

    /// How the last claim of this host went; nil before the first claim.
    public var lastClaim: PageClaimOutcome? { claimState.outcome }

    /// Hands the claim to the current document (``retarget(descriptor:routes:route:documentAttributes:surface:dynamicResources:)``
    /// already bound the routes) and reloads it only when it does not acknowledge.
    func claimDocument(documentAttributes: [String: String]) {
        _ = claimState.end()
        let state = claimState
        let generation = state.generation
        state.pending = true
        state.start = .now
        if let script = Self.attributesScript(documentAttributes) { webView.evaluateJavaScript(script, completionHandler: nil) }
        applyTheme(force: true)
        applyLiveDocumentAttributes()
        let params: JSONValue = route.map { ["route": .string($0)] } ?? .object([:])
        let router = router
        Task { @MainActor [weak self] in
            let path: PageClaimOutcome.Path
            do {
                let reply = try await router.callPage(Self.claimOp, params: params)
                path = reply["claimed"]?.boolValue == true ? .acknowledged : .refused
            } catch {
                path = .refused
            }
            self?.finishClaim(generation, path)
        }
        state.deadline.schedule(after: state.budget) { @MainActor [weak self] in
            self?.finishClaim(generation, .timedOut)
        }
    }

    /// Records a claim that loaded its document.
    func noteLoadedClaim() {
        _ = claimState.end()
        claimState.outcome = PageClaimOutcome(path: .loaded, milliseconds: 0)
    }

    private func finishClaim(_ generation: UInt64, _ path: PageClaimOutcome.Path) {
        let state = claimState
        guard state.generation == generation, state.end() else { return }
        let (seconds, attoseconds) = (ContinuousClock.now - state.start).components
        state.outcome = PageClaimOutcome(path: path,
                                         milliseconds: Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
        guard path != .acknowledged else {
            resumeLoadWaiters()
            return
        }
        loaded = false
        reloadDocument()
    }

    /// Loads the current page URL again (a plain load of the same URL with another fragment is only
    /// a fragment navigation in WebKit, so this reloads from script).
    func reloadDocument() {
        let fragment = route ?? "/"
        webView.evaluateJavaScript("history.replaceState(null, \"\", \(JSONValue.string(fragment).compactText)); location.reload();",
                                   completionHandler: nil)
    }
}
