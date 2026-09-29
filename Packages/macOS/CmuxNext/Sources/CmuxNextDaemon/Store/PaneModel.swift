import Foundation
public import Observation
import os

@Observable @MainActor
public final class PaneModel: Identifiable {
    public let id: String
    public internal(set) var handle: PaneID
    public internal(set) var name: String?
    /// Daemon default tab; the window keeps its own selection.
    public internal(set) var defaultTabIndex: Int
    public internal(set) var focusedAt: UInt64
    public internal(set) var tabs: [TabModel]

    init(_ snapshot: PaneSnapshot) {
        id = Self.identity(snapshot)
        handle = snapshot.id
        defaultTabIndex = snapshot.activeTab
        focusedAt = snapshot.focusedAt
        tabs = snapshot.tabs.map(TabModel.init)
        name = snapshot.name
    }

    static func identity(_ snapshot: PaneSnapshot) -> String {
        snapshot.resourceID?.rawValue ?? "pane:\(snapshot.id.rawValue)"
    }

    func update(_ snapshot: PaneSnapshot) {
        handle = snapshot.id
        name = snapshot.name
        defaultTabIndex = snapshot.activeTab
        focusedAt = snapshot.focusedAt
        tabs = reconcile(tabs, with: snapshot.tabs, id: TabModel.identity, make: TabModel.init) { $0.update($1) }
    }
}

/// Reuses existing models by identity, creates new ones, drops removed ones,
/// and adopts the snapshot order.
@MainActor
func reconcile<Model: AnyObject, Snapshot>(
    _ existing: [Model],
    with snapshots: [Snapshot],
    id: (Snapshot) -> String,
    make: (Snapshot) -> Model,
    update: (Model, Snapshot) -> Void
) -> [Model] where Model: Identifiable, Model.ID == String {
    var byID: [String: Model] = [:]
    for model in existing { byID[model.id] = model }
    return snapshots.map { snapshot in
        if let model = byID.removeValue(forKey: id(snapshot)) {
            update(model, snapshot)
            return model
        }
        return make(snapshot)
    }
}
