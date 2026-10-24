import Foundation
import os

/// One DevTools step of a Chromium page bridge that runs a page script in its own isolated world
/// (`CEFMediaBridge`, `CEFVerificationBridge`): a plain protocol call, or a script run once in
/// that world's existing documents.
///
/// Without `Runtime.enable` a binding reaches only the worlds that exist when it is added, so a
/// page script can find its channel missing and hold what it wanted to send. The bridge then
/// calls the script's ready hook once in the existing worlds (``once(source:world:)``) right
/// after it adds the binding: the held message goes then, with no timer in the page.
enum CEFDevToolsCall {
    /// A DevTools method with its parameters.
    case call(method: String, params: [String: Any])
    /// `source` runs once in the existing documents of `world`: `runImmediately` runs a
    /// new-document script there, and the bridge removes it as soon as it is added, so no later
    /// document runs it (their script finds the binding from the start).
    case once(source: String, world: String)

    /// The script that calls `hook` on its world's `window` when the page script put it there.
    static func readyHook(_ hook: String, world: String) -> CEFDevToolsCall {
        .once(source: "typeof window.\(hook) === 'function' && window.\(hook)()", world: world)
    }

    /// The DevTools method this step sends first.
    var method: String {
        switch self {
        case .call(let method, _): method
        case .once: "Page.addScriptToEvaluateOnNewDocument"
        }
    }

    /// The parameters of ``method``.
    var params: [String: Any] {
        switch self {
        case .call(_, let params): params
        case .once(let source, let world): ["source": source, "worldName": world, "runImmediately": true]
        }
    }

    /// Runs `calls` in order on `tab`'s `browser`; stops when the tab is gone or shows another
    /// browser. A step that fails is logged under `label` and the next one still runs.
    static func run(_ calls: [CEFDevToolsCall], browser: Int32, tab: CEFTab, label: String) {
        // task-owner: one ordered DevTools sequence for one document of one tab; each step ends with the tab's browser
        Task { [weak tab] in
            for step in calls {
                guard let tab, tab.browserID == browser else { return }
                do {
                    let result = try await tab.runtime.devTools(browser, method: step.method, params: step.params)
                    if case .once = step, let identifier = scriptIdentifier(result) {
                        _ = try await tab.runtime.devTools(browser, method: "Page.removeScriptToEvaluateOnNewDocument",
                                                          params: ["identifier": identifier])
                    }
                } catch {
                    tab.runtime.logger.info("\(label, privacy: .public): \(step.method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The `identifier` of a `Page.addScriptToEvaluateOnNewDocument` result.
    static func scriptIdentifier(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["identifier"] as? String
    }
}
