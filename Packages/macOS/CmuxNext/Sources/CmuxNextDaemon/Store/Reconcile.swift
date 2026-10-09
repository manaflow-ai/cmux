import Foundation

/// Reuses existing records by identity, creates new ones, and drops removed
/// ones. Returns nil when the identity order is unchanged, so the caller
/// leaves its array property untouched and observers of the array are not
/// invalidated by field-only changes.
@MainActor
func reconcile<Model: AnyObject & Identifiable, Snapshot>(
    _ existing: [Model],
    with snapshots: [Snapshot],
    id: (Snapshot) -> Model.ID,
    make: (Snapshot) -> Model,
    update: (Model, Snapshot) -> Void
) -> [Model]? {
    var byID: [Model.ID: Model] = [:]
    byID.reserveCapacity(existing.count)
    for model in existing { byID[model.id] = model }
    var changed = existing.count != snapshots.count
    var result: [Model] = []
    result.reserveCapacity(snapshots.count)
    for (index, snapshot) in snapshots.enumerated() {
        let model: Model
        if let reused = byID.removeValue(forKey: id(snapshot)) {
            update(reused, snapshot)
            model = reused
        } else {
            model = make(snapshot)
        }
        if !changed, existing[checked: index].map({ $0 !== model }) ?? true { changed = true }
        result.append(model)
    }
    return changed ? result : nil
}
