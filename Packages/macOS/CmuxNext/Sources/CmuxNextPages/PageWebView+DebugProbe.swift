#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import AppKit

/// The DOM read behind `debug.page {action: "query"}` and `debug.agent_pane {action: "query"}`: every
/// element matching `selector`, in document order, with its `data-*` attributes, classes, the first 120
/// characters of its text as drawn (a closed Details hides its raw words), and, when it has them, its
/// `role` and accessible `label` (`aria-label`, else the text `aria-labelledby` names). A capture's
/// read-back checks what a person and VoiceOver get: a toast stack is a region named "Notifications".
public enum PageDebugQuery {
    /// A page function of `selector`; it answers the elements as JSON text.
    public static let script = """
    return JSON.stringify([...document.querySelectorAll(selector)].map((el) => {
      const item = { data: Object.assign({}, el.dataset), classes: [...el.classList], text: (el.innerText || '').slice(0, 120) };
      const role = el.getAttribute('role');
      if (role) item.role = role;
      const named = (el.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean)
        .map((id) => (document.getElementById(id)?.textContent || '').trim()).filter(Boolean).join(' ');
      const label = (el.getAttribute('aria-label') || '').trim() || named;
      if (label) item.label = label;
      return item;
    }));
    """

    /// `{elements: [...]}` from the script's answer, else `{error}`.
    public static func answer(_ result: Any?) -> JSONValue {
        guard let text = result as? String, let value = try? JSONValue.parse(Data(text.utf8)) else { return ["error": "query failed"] }
        return ["elements": value]
    }

    /// Runs the query for `selector` (default every element) through `call` (a page's own script call),
    /// with `extra` members added to the answer (`debug.agent_pane` names its pane).
    public static func read(_ selector: String?, extra: [String: JSONValue] = [:],
                            call: (String, [String: Any]) async throws -> Any?) async -> JSONValue {
        guard case .object(var members) = answer(try? await call(script, ["selector": selector ?? "*"])) else { return ["error": "query failed"] }
        members.merge(extra) { _, new in new }
        return .object(members)
    }
}

extension PageWebView {
    /// Which live view a probe read (`debug.page`): page id, instance, parked, window number and the
    /// last claim.
    public var debugIdentity: [String: JSONValue] {
        var members: [String: JSONValue] = [
            "page": .string(pageID),
            "instance": .number(Double(PageRegistry.instance(of: self))),
            "parked": .bool(isParkedSpare),
            "window_number": window.map { .number(Double($0.windowNumber)) } ?? .null,
        ]
        if let claim = lastClaim {
            members["claim"] = ["path": .string(claim.path.rawValue), "ms": .number(claim.milliseconds)]
        }
        return members
    }

    /// `debug.page`'s `state`: ``debugState()`` with the identity, the router's subscriptions and calls
    /// still running, the first frame, and why a page may not paint.
    public func debugFullState() async -> JSONValue {
        let state = await debugState()
        guard case .object(var members) = state else { return state }
        members.merge(debugIdentity) { _, new in new }
        members["subscriptions"] = .number(Double(router.subscriptionCount))
        members["in_flight"] = .array(router.inFlightCalls())
        // The first frame of this document (preflights wait on it with a deadline).
        members["painted"] = .bool(hasPainted)
        members["painted_uptime"] = paintedUptime.map { .number($0) } ?? .null
        // Why a page may not paint: no window, a hidden view, or a window macOS reports
        // as occluded (WebKit stops rendering updates for an occluded window).
        members["in_window"] = .bool(window != nil)
        members["view_hidden"] = .bool(isHiddenOrHasHiddenAncestor)
        members["window_visible"] = .bool(window?.isVisible ?? false)
        members["window_occluded"] = .bool(!(window?.occlusionState.contains(.visible) ?? false))
        members["frame"] = .string("\(Int(frame.width))x\(Int(frame.height))")
        return .object(members)
    }
}
#endif
