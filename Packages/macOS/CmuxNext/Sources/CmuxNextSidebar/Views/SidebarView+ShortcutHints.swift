public import AppKit
import CmuxNextDesign

extension SidebarView {
    /// Visible workspace rows in sidebar coordinates, keyed by the selection target.
    public var shortcutHintWorkspaceFrames: [WorkspaceID: CGRect] {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 1 else { return [:] }
        var result: [WorkspaceID: CGRect] = [:]
        for (key, row) in list.rowViews {
            guard case let .workspace(id) = key, row.alphaValue > 0.9 else { continue }
            let rect = row.convert(row.bounds, to: self)
            let viewport = scrollViewFrameForHints
            guard viewport.contains(rect) else { continue }
            result[id] = rect
        }
        return result
    }

    private var scrollViewFrameForHints: CGRect { list.convert(list.visibleRect, to: self) }

    /// Space-switcher slots in sidebar coordinates, in the space selection order.
    public var shortcutHintSpaceFrames: [CGRect] {
        guard !isHiddenOrHasHiddenAncestor, !profileBar.isHidden, bounds.width > 1 else { return [] }
        return ProfileBarLogic.slotXs(count: model.profiles.count, slot: Metrics.roomDotSlot, width: profileBar.bounds.width)
            .prefix(model.profiles.count).map {
                profileBar.convert(CGRect(x: $0, y: 0, width: Metrics.roomDotSlot, height: profileBar.bounds.height), to: self)
            }
    }
}
