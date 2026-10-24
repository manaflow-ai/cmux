import CmuxNextSettings

/// Events a provider sends before its subscription is registered and answered: held in order,
/// then released once, after which events go straight to the page.
@MainActor
final class PageEarlyEvents {
    private var held: [JSONValue]? = []

    /// Whether any event is held (the subscription is not released and something arrived).
    var isHolding: Bool { !(held?.isEmpty ?? true) }

    /// Holds `data` while the subscription is not released yet; false once it is.
    func hold(_ data: JSONValue) -> Bool {
        guard held != nil else { return false }
        held?.append(data)
        return true
    }

    /// The held events, oldest first; later events are not held.
    func release() -> [JSONValue] {
        defer { held = nil }
        return held ?? []
    }
}
