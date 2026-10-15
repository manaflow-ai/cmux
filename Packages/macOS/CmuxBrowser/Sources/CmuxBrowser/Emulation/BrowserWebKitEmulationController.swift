public import Foundation
public import WebKit

/// The content-blocker rules that cut a page off from the network while
/// ``BrowserEmulationOverrides/offline`` is set: every http(s) and ws(s) load
/// fails, as it does with no connection. Local schemes (`file:`, `data:`,
/// `blob:`, `about:`, cmux's own handlers) keep working.
public enum BrowserOfflineContentRules {
    /// The rule-list store identifier.
    public static let identifier = "cmux.browser.emulation.offline"

    /// The rules as content-blocker JSON.
    public static let encodedRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """
}

/// Applies ``BrowserEmulationOverrides`` to a WKWebView and keeps them for
/// the web views that later replace it (a discarded or crashed page).
///
/// One per browser tab. A changed value takes effect in the loaded document
/// at once and in every document loaded after it, in all frames.
@MainActor
public final class BrowserWebKitEmulationController {
    public private(set) var overrides = BrowserEmulationOverrides()

    private let ruleListStore: () -> WKContentRuleListStore?
    private var offlineRuleList: WKContentRuleList?

    /// - Parameter ruleListStore: Where the offline rules compile (tests pass
    ///   a store in a temporary directory).
    public init(ruleListStore: @escaping () -> WKContentRuleListStore? = { WKContentRuleListStore.default() }) {
        self.ruleListStore = ruleListStore
    }

    /// Sets `overrides` on `webView`: future documents through a user
    /// script, the loaded main-frame document by evaluating the same script.
    /// - Throws: ``BrowserEmulationError/offlineRulesUnavailable`` when the
    ///   offline rules cannot compile; nothing changes then.
    public func update(_ newOverrides: BrowserEmulationOverrides, on webView: WKWebView) async throws {
        if newOverrides.offline, offlineRuleList == nil {
            offlineRuleList = try await compileOfflineRuleList()
        }
        let previous = overrides
        overrides = newOverrides
        let userContentController = webView.configuration.userContentController
        if previous.offline != newOverrides.offline, let offlineRuleList {
            if newOverrides.offline {
                userContentController.add(offlineRuleList)
            } else {
                userContentController.remove(offlineRuleList)
            }
        }
        // User scripts cannot be removed one at a time; each change adds one
        // that overwrites the values the earlier ones stored.
        userContentController.addUserScript(Self.userScript(for: newOverrides))
        _ = try? await webView.evaluateJavaScript(
            BrowserEmulationScript.source(for: newOverrides, dispatchesChangeEvents: true),
            in: nil,
            contentWorld: .page
        )
    }

    /// Installs the current overrides on a web view that replaces the tab's
    /// previous one. Does nothing while no override is set.
    public func install(on webView: WKWebView) {
        guard !overrides.isDefault else { return }
        let userContentController = webView.configuration.userContentController
        if overrides.offline, let offlineRuleList {
            userContentController.add(offlineRuleList)
        }
        userContentController.addUserScript(Self.userScript(for: overrides))
    }

    /// Forgets the overrides without touching any web view: the tab's web
    /// view is being replaced by one that should start without them (a
    /// profile switch or a context reset).
    public func reset() {
        overrides = BrowserEmulationOverrides()
    }

    private static func userScript(for overrides: BrowserEmulationOverrides) -> WKUserScript {
        WKUserScript(
            source: BrowserEmulationScript.source(for: overrides, dispatchesChangeEvents: false),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    private func compileOfflineRuleList() async throws -> WKContentRuleList {
        guard let store = ruleListStore() else { throw BrowserEmulationError.offlineRulesUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: BrowserOfflineContentRules.identifier,
                encodedContentRuleList: BrowserOfflineContentRules.encodedRules
            ) { list, _ in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: BrowserEmulationError.offlineRulesUnavailable)
                }
            }
        }
    }
}

public enum BrowserEmulationError: Error, Equatable, Sendable {
    /// WebKit could not compile the offline content rules.
    case offlineRulesUnavailable
}
