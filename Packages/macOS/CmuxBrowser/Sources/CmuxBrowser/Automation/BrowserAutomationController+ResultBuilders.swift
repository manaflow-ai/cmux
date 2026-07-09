public import Foundation
public import WebKit

extension BrowserAutomationController {
    /// Builds the diagnostic payload for a `browser.*` element-action that failed
    /// to locate its selector: evaluates the package's not-found diagnostics
    /// script against `webView` (through the host's worker-lane JS-eval seam) and
    /// folds the match counts, sample, excerpts, title/url, and any diagnostics
    /// code/details into a `selector`-keyed Foundation dictionary.
    ///
    /// `nonisolated`: runs on the socket worker lane; the live `WKWebView` is
    /// resolved app-side and handed in, and the actual evaluation hops to the main
    /// actor inside ``BrowserControlHosting/v2RunBrowserJavaScript``.
    public nonisolated func browserNotFoundDiagnostics(
        surfaceId: UUID,
        webView: WKWebView,
        selector: String,
        host: any BrowserControlHosting
    ) -> [String: Any] {
        let script = control.notFoundDiagnosticsScript(selector: selector)

        switch host.v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: script,
            timeout: 4.0,
            useEval: true,
            onIsolatedWorldFallback: nil
        ) {
        case .failure(let message):
            return [
                "selector": selector,
                "diagnostics_error": message
            ]
        case .success(let value):
            guard let dict = value as? [String: Any] else {
                return ["selector": selector]
            }
            var out: [String: Any] = ["selector": selector]
            if let count = dict["count"] { out["match_count"] = count }
            if let visibleCount = dict["visible_count"] { out["visible_match_count"] = visibleCount }
            if let sample = dict["sample"] { out["sample"] = normalizeJSValue(sample) }
            if let excerpt = dict["snapshot_excerpt"] { out["snapshot_excerpt"] = excerpt }
            if let body = dict["body_excerpt"] { out["body_excerpt"] = body }
            if let title = dict["title"] { out["title"] = title }
            if let url = dict["url"] { out["url"] = url }
            if let err = dict["error"] { out["diagnostics_code"] = err }
            if let details = dict["details"] { out["diagnostics_details"] = details }
            return out
        }
    }

    /// Builds the `not_found` command result for a `browser.*` element action:
    /// gathers ``browserNotFoundDiagnostics(surfaceId:webView:selector:host:)``,
    /// annotates it with the action name, retry count, and refresh hint, and
    /// produces the human-readable message from the package's
    /// ``BrowserControlService/elementNotFoundMessage(selector:matchCount:visibleCount:)``.
    public nonisolated func browserElementNotFoundResult(
        actionName: String,
        selector: String,
        attempts: Int,
        surfaceId: UUID,
        webView: WKWebView,
        host: any BrowserControlHosting
    ) -> BrowserCommandResult {
        var data = browserNotFoundDiagnostics(
            surfaceId: surfaceId,
            webView: webView,
            selector: selector,
            host: host
        )
        data["action"] = actionName
        data["retry_attempts"] = attempts
        data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

        let count = (data["match_count"] as? Int) ?? (data["match_count"] as? NSNumber)?.intValue ?? 0
        let visibleCount = (data["visible_match_count"] as? Int) ?? (data["visible_match_count"] as? NSNumber)?.intValue ?? 0

        let message = control.elementNotFoundMessage(
            selector: selector,
            matchCount: count,
            visibleCount: visibleCount
        )

        return .err(code: "not_found", message: message, data: data)
    }

    /// Appends the optional `post_action_*` snapshot fields to a command's success
    /// `payload` when the request asked for `snapshot_after`: assembles the
    /// snapshot params from the `snapshot_*` flags, drives the host's snapshot
    /// command through the seam, and merges its snapshot/refs/title/url (or error)
    /// into the payload in place.
    public nonisolated func appendPostSnapshot(
        params: [String: Any],
        surfaceId: UUID,
        payload: inout [String: Any],
        host: any BrowserControlHosting
    ) {
        guard Self.boolParam(params, "snapshot_after") ?? false else { return }

        var snapshotParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "interactive": Self.boolParam(params, "snapshot_interactive") ?? true,
            "cursor": Self.boolParam(params, "snapshot_cursor") ?? false,
            "compact": Self.boolParam(params, "snapshot_compact") ?? true,
            "max_depth": max(0, Self.intParam(params, "snapshot_max_depth") ?? 10)
        ]
        if let selector = Self.stringParam(params, "snapshot_selector"),
           !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotParams["selector"] = selector
        }

        switch host.v2BrowserSnapshot(params: snapshotParams) {
        case .ok(let snapshotAny):
            guard let snapshot = snapshotAny as? [String: Any] else {
                payload["post_action_snapshot_error"] = [
                    "code": "internal_error",
                    "message": "Invalid snapshot payload"
                ]
                return
            }
            if let value = snapshot["snapshot"] {
                payload["post_action_snapshot"] = value
            }
            if let value = snapshot["refs"] {
                payload["post_action_refs"] = value
            }
            if let value = snapshot["title"] {
                payload["post_action_title"] = value
            }
            if let value = snapshot["url"] {
                payload["post_action_url"] = value
            }
        case .err(code: let code, message: let message, data: let data):
            var err: [String: Any] = [
                "code": code,
                "message": message,
            ]
            err["data"] = Self.orNull(data)
            payload["post_action_snapshot_error"] = err
        }
    }

    // Leaf param parsers (`boolParam`/`intParam`/`stringParam`/`orNull`) live in
    // `BrowserAutomationController+Params.swift`, shared with the selector-action
    // and getter/predicate command bodies.
}
