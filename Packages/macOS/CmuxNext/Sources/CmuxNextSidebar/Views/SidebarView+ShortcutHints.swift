public import AppKit
import CmuxNextDesign

extension SidebarViewComponents {
    /// Every fully visible sidebar destination in sidebar coordinates, keyed by
    /// the ``SidebarItem`` that Cmd-digit selects (``SidebarItemOrder/number(for:_:)``).
    public var shortcutHintItemFrames: [SidebarItem: CGRect] {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 1 else { return [:] }
        var result: [SidebarItem: CGRect] = [:]
        for (key, row) in list.rowViews {
            guard case let .workspace(id) = key, row.alphaValue > 0.9 else { continue }
            let rect = row.convert(row.bounds, to: self)
            let viewport = scrollViewFrameForHints
            guard viewport.contains(rect) else { continue }
            result[.workspace(id)] = rect
        }
        return result
    }

    private var scrollViewFrameForHints: CGRect { list.convert(list.visibleRect, to: self) }

    /// Space-switcher slots in sidebar coordinates, in the space selection order.
    public var shortcutHintSpaceFrames: [CGRect] {
        // No hints over a strip faded out (`sidebar.spacesVisibility` hover).
        guard !isHiddenOrHasHiddenAncestor, !profileBar.isHidden, profileBar.alphaValue > 0.5, bounds.width > 1 else { return [] }
        return profileBar.slotRects().prefix(model.profiles.count).map { profileBar.convert($0, to: self) }
    }
}
