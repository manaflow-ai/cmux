import Foundation
public import WebKit

/// Applies ``BrowserEmulationOverrides`` to a WKWebView and keeps them for
/// the web views that later replace it (a discarded or crashed page).
///
/// One per browser tab. A change reaches the loaded main-frame document at
/// once, and every document loaded after it in all frames. Subframes that
/// are already loaded keep their values until they load again; their network
/// loads are blocked at once all the same.
///
/// What a web view has installed (the offline rule list, the emulation user
/// script) is recorded per `WKUserContentController`. A popup WebKit creates
/// from its opener's configuration shares that controller, so the two share
/// their emulation, and adding and removing stays paired either way.
@MainActor
public final class BrowserWebKitEmulationController {
    /// The rule-list store identifier of the offline rules.
    public static let offlineRuleListIdentifier = "cmux.browser.emulation.offline"

    /// The content-blocker rules that cut a page off from the network while
    /// ``BrowserEmulationOverrides/offline`` is set: every http(s) and ws(s)
    /// load fails, as it does with no connection. Local schemes (`file:`,
    /// `data:`, `blob:`, `about:`, cmux's own handlers) keep working.
    public static let offlineEncodedRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """

    /// What each user content controller has installed.
    private static let installations = NSMapTable<WKUserContentController, InstallationBox>.weakToStrongObjects()

    public private(set) var overrides = BrowserEmulationOverrides()

    private let ruleListStore: () -> WKContentRuleListStore?
    private var offlineRuleList: WKContentRuleList?
    /// Bumped by ``reset()``; an update that started before a reset does not
    /// apply after it.
    private var generation = 0

    /// - Parameter ruleListStore: Where the offline rules compile (tests pass
    ///   a store in a temporary directory).
    public init(ruleListStore: @escaping () -> WKContentRuleListStore? = { WKContentRuleListStore.default() }) {
        self.ruleListStore = ruleListStore
    }

    /// Applies `change` to the current overrides on the web view `webView()`
    /// returns at the moment of applying.
    ///
    /// The only suspension is compiling the offline rules, before anything
    /// changes. `change` then runs on the values current at that point, so two
    /// overlapping updates both land, and the web view is read after the
    /// suspension, so a replacement made meanwhile gets the change.
    /// - Returns: The overrides now in effect.
    /// - Throws: ``BrowserEmulationError/offlineRulesUnavailable`` when the
    ///   offline rules cannot compile, ``BrowserEmulationError/superseded``
    ///   when ``reset()`` ran or the task was cancelled meanwhile. Nothing
    ///   changes then.
    @discardableResult
    public func update(
        on webView: () -> WKWebView,
        _ change: (inout BrowserEmulationOverrides) -> Void
    ) async throws -> BrowserEmulationOverrides {
        var preview = overrides
        change(&preview)
        if preview.offline, offlineRuleList == nil {
            let startedGeneration = generation
            let compiled = try await compileOfflineRuleList()
            offlineRuleList = compiled
            guard generation == startedGeneration, !Task.isCancelled else {
                throw BrowserEmulationError.superseded
            }
        }
        var next = overrides
        change(&next)
        overrides = next
        let target = webView()
        install(next, on: target.configuration.userContentController)
        target.evaluateJavaScript(
            next.pageScript(dispatchesChangeEvents: true),
            in: nil,
            in: .page,
            completionHandler: nil
        )
        return next
    }

    /// Installs the current overrides on a web view that replaces the tab's
    /// previous one.
    public func install(on webView: WKWebView) {
        install(overrides, on: webView.configuration.userContentController)
    }

    /// Forgets the overrides without touching any web view: the tab's web
    /// view is being replaced by one that should start without them (a
    /// profile switch or a context reset).
    public func reset() {
        overrides = BrowserEmulationOverrides()
        generation += 1
    }

    /// Brings `controller` to `overrides`: the rule list present exactly
    /// while offline, and at most one emulation user script.
    private func install(_ overrides: BrowserEmulationOverrides, on controller: WKUserContentController) {
        let box = Self.installations.object(forKey: controller) ?? InstallationBox()
        Self.installations.setObject(box, forKey: controller)

        if overrides.offline != box.hasOfflineRules, let offlineRuleList {
            if overrides.offline {
                controller.add(offlineRuleList)
            } else {
                controller.remove(offlineRuleList)
            }
            box.hasOfflineRules = overrides.offline
        }

        // A controller that never had a script and stays at the defaults
        // needs none.
        guard box.scriptOverrides != overrides,
              box.userScript != nil || !overrides.isDefault else { return }
        if let previous = box.userScript {
            // A user script cannot be removed alone; keep every other one.
            let kept = controller.userScripts.filter { $0 !== previous }
            controller.removeAllUserScripts()
            kept.forEach(controller.addUserScript)
        }
        // Back at the defaults the script still runs once per document, so a
        // page loaded later gets the defaults rather than stale values held
        // by a document that stayed in the back/forward cache.
        let script = WKUserScript(
            source: overrides.pageScript(dispatchesChangeEvents: false),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        controller.addUserScript(script)
        box.userScript = script
        box.scriptOverrides = overrides
    }

    private func compileOfflineRuleList() async throws -> WKContentRuleList {
        guard let store = ruleListStore() else { throw BrowserEmulationError.offlineRulesUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: Self.offlineRuleListIdentifier,
                encodedContentRuleList: Self.offlineEncodedRules
            ) { list, _ in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: BrowserEmulationError.offlineRulesUnavailable)
                }
            }
        }
    }

    /// What the controller installed on one user content controller.
    private final class InstallationBox {
        var hasOfflineRules = false
        var userScript: WKUserScript?
        /// The values `userScript` carries.
        var scriptOverrides: BrowserEmulationOverrides?
    }
}

public enum BrowserEmulationError: Error, Equatable, Sendable {
    /// WebKit could not compile the offline content rules.
    case offlineRulesUnavailable
    /// The tab was reset, or the request cancelled, before the change applied.
    case superseded
}
