import CoreGraphics

/// One row as the table renders it, or will render it.
struct WorkspaceListRenderedRow<Model: Equatable, ActionKey: Equatable>: Equatable {
    var model: Model
    var nativeActions: ActionKey?
    var height: CGFloat
}

/// Classifies the difference between what a table shows and a newer snapshot.
///
/// Content that keeps its row's height can reach the screen at any moment
/// without moving anything. Everything else (identity, order, height, native
/// swipe actions) is geometry: UIKit must lay rows out again, which the table
/// commits only while the user is not moving the list.
struct WorkspaceListUpdatePlan<Model: Equatable, ActionKey: Equatable> {
    typealias Row = WorkspaceListRenderedRow<Model, ActionKey>

    /// Surviving rows whose content changed and whose height did not, in
    /// target order.
    private(set) var contentOnlyIDs: [String] = []
    /// Surviving rows whose height changed.
    private(set) var heightChangedIDs: Set<String> = []
    /// Surviving rows whose native swipe actions changed.
    private(set) var nativeActionChangedIDs: Set<String> = []
    let structureChanged: Bool
    /// The minimal edit script from the rendered order to the target order,
    /// with moves inferred. Empty when the order is unchanged.
    let difference: CollectionDifference<String>
    /// Surviving rows that keep their place relative to their neighbors.
    ///
    /// Everything the edit script does not delete, insert or move holds its
    /// place, so these are the only safe viewport anchors: pinning the
    /// viewport to a row that itself jumped (a notification moving it to the
    /// top) would carry the viewport with it.
    let stableIDs: Set<String>

    var needsGeometryCommit: Bool {
        structureChanged || !heightChangedIDs.isEmpty || !nativeActionChangedIDs.isEmpty
    }

    var isEmpty: Bool {
        contentOnlyIDs.isEmpty && !needsGeometryCommit
    }

    init(
        renderedIDs: [String],
        renderedRows: [String: Row],
        targetIDs: [String],
        targetRows: [String: Row]
    ) {
        structureChanged = renderedIDs != targetIDs
        difference = targetIDs.difference(from: renderedIDs).inferringMoves()
        var unstable = Set<String>()
        for change in difference {
            switch change {
            case .insert(_, let element, _), .remove(_, let element, _):
                unstable.insert(element)
            }
        }
        stableIDs = Set(renderedIDs).intersection(targetIDs).subtracting(unstable)
        for id in targetIDs {
            guard let rendered = renderedRows[id], let target = targetRows[id] else { continue }
            if rendered.height != target.height {
                heightChangedIDs.insert(id)
            } else if rendered.model != target.model {
                contentOnlyIDs.append(id)
            }
            if rendered.nativeActions != target.nativeActions {
                nativeActionChangedIDs.insert(id)
            }
        }
    }
}
