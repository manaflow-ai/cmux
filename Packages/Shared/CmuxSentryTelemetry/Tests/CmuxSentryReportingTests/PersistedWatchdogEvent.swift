import Sentry

/// Models the SDK serialization contract without calling its private breadcrumb setter.
final class PersistedWatchdogEvent: Event {
    var persistedTimeline: [[String: Any]] = []

    override func serialize() -> [String: Any] {
        var payload = super.serialize()
        payload["breadcrumbs"] = persistedTimeline
        return payload
    }
}
