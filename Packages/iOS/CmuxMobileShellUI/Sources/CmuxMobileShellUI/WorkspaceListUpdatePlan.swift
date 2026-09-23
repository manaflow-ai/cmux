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

/// Which surviving rows keep their relative order across an identity change.
///
/// A minimal edit script moves as few rows as possible; everything it does not
/// delete, insert or move holds its place relative to its neighbors. Those
/// rows are the only safe viewport anchors: pinning the viewport to a row that
/// itself jumped (a notification moving it to the top) would carry the
/// viewport with it.
enum WorkspaceListStableRows {
    static func ids(from old: [String], to new: [String]) -> Set<String> {
        let difference = new.difference(from: old).inferringMoves()
        var unstable = Set<String>()
        for change in difference {
            switch change {
            case .insert(_, let element, _), .remove(_, let element, _):
                unstable.insert(element)
            }
        }
        return Set(old).intersection(new).subtracting(unstable)
    }
}
