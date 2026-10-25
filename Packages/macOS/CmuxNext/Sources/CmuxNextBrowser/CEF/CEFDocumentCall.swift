import Foundation
import os

/// One DevTools step of a document bridge (`CEFMediaBridge`, `CEFVerificationBridge`), for
/// Chromium forks before API 29, where each tab installs cmux's document scripts over its own
/// DevTools session.
///
/// Without `Runtime.enable` a binding reaches only the worlds that exist when it is added, and a
/// script that found its binding missing waits with no timer. So after each binding add the
/// bridge calls that script's ready hook once in the worlds that exist now (``readyHook(world:hook:)``):
/// the waiting script sends then.
enum CEFDocumentCall {
    /// A DevTools method call.
    case method(String, [String: Any])
    /// One call of `hook` (a function on the `window` of each world named `world`) in the worlds
    /// that exist now: `Page.addScriptToEvaluateOnNewDocument` with `runImmediately`, removed at
    /// once so later documents (which find their binding from the start) never run it. Two round
    /// trips.
    case readyHook(world: String, hook: String)

    /// The DevTools method the step starts with.
    var method: String {
        switch self {
        case .method(let method, _): method
        case .readyHook: "Page.addScriptToEvaluateOnNewDocument"
        }
    }

    /// Runs `calls` in order on `browser` while the tab still shows it; a failed call is logged
    /// under `label` and the next one runs.
    static func run(_ calls: [CEFDocumentCall], on tab: CEFTab, browser: Int32, label: String) {
        Task { [weak tab] in
            for call in calls {
                guard let tab, tab.browserID == browser else { return }
                do {
                    switch call {
                    case .method(let method, let params):
                        _ = try await tab.runtime.devTools(browser, method: method, params: params)
                    case .readyHook(let world, let hook):
                        let result = try await tab.runtime.devTools(browser, method: call.method,
                                                                    params: ["source": CEFDocumentCall.readySource(hook: hook), "worldName": world, "runImmediately": true])
                        if let identifier = CEFDocumentCall.scriptIdentifier(result) {
                            _ = try await tab.runtime.devTools(browser, method: "Page.removeScriptToEvaluateOnNewDocument",
                                                              params: ["identifier": identifier])
                        }
                    }
                } catch {
                    tab.runtime.logger.info("\(label, privacy: .public): \(call.method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The script a ``readyHook(world:hook:)`` runs: calls `hook` where the world defines it.
    static func readySource(hook: String) -> String {
        "typeof window.\(hook) === 'function' && window.\(hook)()"
    }

    /// The `identifier` of a `Page.addScriptToEvaluateOnNewDocument` result.
    private static func scriptIdentifier(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["identifier"] as? String
    }
}
