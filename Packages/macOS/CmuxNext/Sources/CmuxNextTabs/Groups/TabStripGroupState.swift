import CmuxNextDesign
import CoreGraphics

/// Group-related state of a `TabStripView`, kept in one struct so the view
/// file stays small.
struct TabStripGroupState {
    struct Drag {
        var groupID: TabGroupID
        var memberIDs: [TabID]
        var grabOffset: CGFloat
        var originalTabIndex: Int
        var currentTabIndex: Int
        /// Content x of the chip's leading edge (follows the pointer).
        var blockX: CGFloat
        var lastPoint: CGPoint
        /// Press y in the clip (flipped); with `grabOffset`, the grabbed point.
        var grabY: CGFloat = 0
    }

    struct Press {
        var groupID: TabGroupID
        var start: CGPoint
        /// A click-and-hold opened the editor, so mouse up does not toggle.
        var openedEditor = false
    }

    var chips: [TabGroupID: TabGroupChipCell] = [:]
    var bands: [TabGroupID: TabGroupBandCell] = [:]
    /// Model groups by id, refreshed on every sync.
    var byID: [TabGroupID: TabGroupItem] = [:]
    /// Membership shown after a local drag until the model's membership changes.
    var membershipOverride: [TabID: TabGroupID?] = [:]
    /// Model membership at the last sync, to detect the App applying a change.
    var lastMembership: [TabGroupID?] = []
    var drag: Drag?
    var press: Press?
    var hoveredChip: TabGroupID?
    /// Group torn out of this strip and handed to the App's drag session.
    var detachedGroupID: TabGroupID?
    /// Payload of the external drag this strip last answered for.
    var dropPayload: TabDragPayload?
    /// Width of the gap an external group drag opens.
    var phantomWidth: CGFloat?
    /// Click-and-hold timer for the editor bubble.
    var holdTask: Task<Void, Never>?
    /// Injected so tests and demos can drive the hold delay.
    // wakeup-allow: one-shot click-and-hold delay (injected for tests), cancelled on mouse up
    var sleep: @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }

    func chipWidths() -> [TabGroupID: CGFloat] {
        chips.mapValues(\.slotWidth)
    }

    /// Chip or member of the dragged group.
    func isDragged(_ id: TabID) -> Bool {
        guard let drag else { return false }
        return id.chipGroupID == drag.groupID || drag.memberIDs.contains(id)
    }
}
