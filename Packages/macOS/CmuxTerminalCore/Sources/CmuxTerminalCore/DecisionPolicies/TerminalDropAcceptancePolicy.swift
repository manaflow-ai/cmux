import Foundation
import UniformTypeIdentifiers

/// Pure drag-acceptance decision for a terminal surface's
/// `NSDraggingDestination` overrides.
///
/// This is the terminal-domain home of the predicate that was triplicated
/// across `GhosttyNSView.draggingEntered`, `draggingUpdated`, and
/// `performDragOperation`. Each override keeps its AppKit `NSDraggingInfo`
/// handling and DEBUG logging app-side, resolves the dragging pasteboard's
/// type `rawValue`s plus the surface's drop-type / tab-transfer /
/// sidebar-reorder `rawValue`s, and forwards the stateless classification here
/// so the decision stays a deterministic, testable value computation.
public enum TerminalDropAcceptancePolicy: Sendable {
    /// Whether a terminal surface should accept (`.copy`) or refuse a drag.
    public enum Decision: Sendable, Equatable {
        /// The drag is not for the terminal; bonsplit or another destination
        /// should handle it. Overrides map this to an empty `NSDragOperation`
        /// (or `false` for `performDragOperation`).
        case reject
        /// The terminal accepts the drag as a copy.
        case copy
    }

    /// Whether a drag should be deferred to bonsplit because a tab-transfer or
    /// sidebar-reorder drag is in flight.
    ///
    /// bonsplit's pane drop overlays should win over the terminal's text/file
    /// drop handling, so all three `NSDraggingDestination` overrides refuse
    /// these drags. `performDragOperation` uses only this gate (it has already
    /// been vetted by `draggingEntered`/`draggingUpdated`), while the entered /
    /// updated phases additionally apply the drop-type test via ``decide``.
    public static func isBonsplitDrag(
        draggedTypes: Set<String>,
        tabTransferType: String,
        sidebarTabReorderType: String
    ) -> Bool {
        draggedTypes.contains(tabTransferType) || draggedTypes.contains(sidebarTabReorderType)
    }

    /// Classifies a drag by the pasteboard's available type `rawValue`s.
    ///
    /// Defers to bonsplit when a tab-transfer or sidebar-reorder drag is in
    /// flight (see ``isBonsplitDrag(draggedTypes:tabTransferType:sidebarTabReorderType:)``),
    /// rejects when the dragged types share nothing with the surface's accepted
    /// drop types, and otherwise accepts the drag as a copy.
    public static func decide(
        draggedTypes: Set<String>,
        dropTypes: Set<String>,
        tabTransferType: String,
        sidebarTabReorderType: String
    ) -> Decision {
        if isBonsplitDrag(
            draggedTypes: draggedTypes,
            tabTransferType: tabTransferType,
            sidebarTabReorderType: sidebarTabReorderType
        ) {
            return .reject
        }
        if draggedTypes.isDisjoint(with: dropTypes) {
            return .reject
        }
        return .copy
    }

    /// The image pasteboard type identifier for a file extension, or `nil` when
    /// the extension is not a known image type.
    ///
    /// Trims whitespace from the extension, resolves its `UTType`, and returns
    /// the identifier only when the type conforms to `.image`. Used by the
    /// DEBUG drop-injection path to write image data under the right type.
    public static func imagePasteboardTypeIdentifier(forExtension pathExtension: String) -> String? {
        let trimmed = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utType = UTType(filenameExtension: trimmed),
              utType.conforms(to: .image) else { return nil }
        return utType.identifier
    }
}
