public import CmuxNextSettings
import Foundation

/// What the sidebar's React update surfaces read (`cmux.changelog.surface.get` and the
/// `cmux.changelog.surface.changes` stream; the App's `UpdateSurfaceProvider` answers them).
extension UpdaterService {
    /// The highlights an update surface shows: the staged update's for the Ready popover; for the
    /// "cmux Updated!" card (`updated`), the last update's, else this version's without a record.
    /// The surface page's JSON: the highlights, and on the Updated card the way back.
    public func surfaceJSON(updated: Bool, background: Bool) throws -> JSONValue {
        try surfaceHighlights(updated: updated)?.surfaceJSON(background: background, goBack: updated ? goBackJSON : .null) ?? .null
    }

    public func surfaceHighlights(updated: Bool) -> UpdateHighlights? {
        guard updated else { return stagedHighlights }
        return lastUpdateHighlights ?? updatedWithoutRecordHighlights
    }
}

extension UpdateHighlights {
    /// The surface page's JSON of these highlights. `background`: the Updated card after an
    /// automatic install that relaunched cmux behind another app (nobody clicked Restart to
    /// Update), so the card says it updated in the background (`"delivery": "background"`).
    public func surfaceJSON(background: Bool, goBack: JSONValue = .null) throws -> JSONValue {
        let value = try JSONValue.parse(JSONEncoder().encode(self))
        guard case .object(var members) = value else { return value }
        if background { members["delivery"] = .string("background") }
        // The Updated card's way back (``UpdaterService/goBackJSON``); absent before an update.
        if goBack != .null { members["goBack"] = goBack }
        return .object(members)
    }
}
