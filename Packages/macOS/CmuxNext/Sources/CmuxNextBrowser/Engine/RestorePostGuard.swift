import Foundation


/// Never send a restored form submission again.
///
/// Restoring a saved history (hibernation wake, tab duplication) loads its
/// current entry. When that entry came from a POST, WebKit sends the form
/// again with no prompt (lane 9 prototype P1/P2: policy `POST backForward`,
/// then `POST formResubmitted`). While a restore is in progress, every
/// main-frame POST that the restore itself starts is cancelled; a form the
/// user submits (`formSubmitted`) still goes through.
nonisolated enum RestorePostGuard {
    enum NavigationType: Sendable {
        case linkActivated, formSubmitted, backForward, reload, formResubmitted, other
    }

    static func shouldCancel(restoring: Bool, isMainFrame: Bool, method: String?, type: NavigationType) -> Bool {
        guard restoring, isMainFrame, method?.uppercased() == "POST" else { return false }
        return type != .formSubmitted
    }
}

/// The original tab's top-origin sessionStorage for a duplicate: a
/// document-start script in an app-private world writes it before the
/// page's own scripts run, only on the original origin.
nonisolated struct DuplicateSessionSeed: Equatable, Sendable {
    /// The content world the seed runs in (never the page or agent world).
    static let worldName = "cmux.duplicate"

    var origin: String
    var items: [String: String]

    /// The script, or empty when there is nothing to seed.
    var scriptSource: String {
        guard !items.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys, .withoutEscapingSlashes]),
              let originData = try? JSONSerialization.data(withJSONObject: [origin], options: [.withoutEscapingSlashes]) else { return "" }
        // `<` and `>` escaped so the JSON can never close a script element.
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        let originLiteral = String(String(decoding: originData, as: UTF8.self).dropFirst().dropLast())
        return """
        (() => { if (location.origin !== \(originLiteral)) return; \
        const items = \(json); \
        try { for (const key of Object.keys(items)) sessionStorage.setItem(key, items[key]); } catch (e) {} })();
        """
    }
}
