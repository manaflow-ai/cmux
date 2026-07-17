public import Foundation

/// Per-Mac local persistence for the dispatch composer: the in-progress draft
/// and the serial counter stamped on the work-order header.
///
/// Drafts survive dismissing the sheet; the serial increments only when a
/// dispatch actually launches, so `Nº` numbers real work orders.
@MainActor
public struct DispatchLocalStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func draftKey(macID: String) -> String { "mobile.dispatch.draft.\(macID)" }
    private func serialKey(macID: String) -> String { "mobile.dispatch.serial.\(macID)" }

    public func draft(macID: String) -> DispatchDraft? {
        guard let data = defaults.data(forKey: draftKey(macID: macID)) else { return nil }
        return try? JSONDecoder().decode(DispatchDraft.self, from: data)
    }

    public func saveDraft(_ draft: DispatchDraft, macID: String) {
        if draft.isEmpty {
            defaults.removeObject(forKey: draftKey(macID: macID))
            return
        }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: draftKey(macID: macID))
    }

    public func clearDraft(macID: String) {
        defaults.removeObject(forKey: draftKey(macID: macID))
    }

    /// The count of completed dispatches for this Mac.
    public func completedCount(macID: String) -> Int {
        defaults.integer(forKey: serialKey(macID: macID))
    }

    /// The serial shown on the next work order (1-based).
    public func nextSerial(macID: String) -> Int {
        completedCount(macID: macID) + 1
    }

    public func recordCompletedDispatch(macID: String) {
        defaults.set(completedCount(macID: macID) + 1, forKey: serialKey(macID: macID))
    }
}
