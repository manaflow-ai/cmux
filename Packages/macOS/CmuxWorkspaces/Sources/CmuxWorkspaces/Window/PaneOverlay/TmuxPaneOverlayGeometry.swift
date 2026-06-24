public import CoreGraphics
public import AppKit
public import Bonsplit

/// Pure geometry for placing the tmux-style pane overlay (unread dots and the
/// attention flash) over a Bonsplit split layout.
///
/// All inputs are Bonsplit value snapshots (`LayoutSnapshot`, `PaneID`) plus the
/// titlebar-chrome inset to trim from the top of each pane; there is no
/// dependency on the app's `Workspace`, AppKit windows, or notification state.
/// The app layer resolves which panes are unread or flashing and then asks this
/// type for the matching rectangles, keeping the placement math testable in
/// isolation and identical across every call site.
public struct TmuxPaneOverlayGeometry: Sendable, Equatable {
    /// Height of the titlebar chrome trimmed off the top of each pane rect so the
    /// overlay covers only the terminal content, not the tab strip.
    public let topChromeHeight: CGFloat

    /// Creates a geometry resolver.
    /// - Parameter topChromeHeight: titlebar chrome height to trim from the top of
    ///   each resolved pane rectangle.
    public init(topChromeHeight: CGFloat) {
        self.topChromeHeight = topChromeHeight
    }

    /// Trims the titlebar chrome inset off the top of `rect`.
    /// - Parameter rect: the full pane rectangle.
    /// - Returns: the pane rectangle with the top chrome removed, clamped so the
    ///   height never drops below zero.
    public func contentRect(_ rect: CGRect) -> CGRect {
        let topInset = min(topChromeHeight, max(0, rect.height - 1))
        return CGRect(
            x: rect.origin.x,
            y: rect.origin.y + topInset,
            width: rect.width,
            height: max(0, rect.height - topInset)
        )
    }

    /// Resolves the trimmed content rectangle for a single pane in a layout
    /// snapshot.
    /// - Parameters:
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - paneId: the pane to resolve, if any.
    ///   - includeContainerOffset: when `true` only the container y-offset is
    ///     removed (window-content space); when `false` both axes are offset by the
    ///     container origin (workspace-local space).
    /// - Returns: the trimmed pane content rect, or `nil` when the snapshot or pane
    ///   is missing.
    private func paneRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?,
        includeContainerOffset: Bool
    ) -> CGRect? {
        guard let layoutSnapshot,
              let paneId,
              let paneRect = layoutSnapshot.panes
                .first(where: { $0.paneId == paneId.id.uuidString })?
                .frame
                .cgRect else {
            return nil
        }

        let rect: CGRect
        if includeContainerOffset {
            rect = paneRect.offsetBy(
                dx: 0,
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        } else {
            rect = paneRect.offsetBy(
                dx: -CGFloat(layoutSnapshot.containerFrame.x),
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        }
        return contentRect(rect)
    }

    /// Resolves a pane's overlay rect in workspace-local coordinates (the
    /// container origin is subtracted on both axes).
    /// - Parameters:
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - paneId: the pane to resolve, if any.
    /// - Returns: the workspace-local content rect, or `nil` when unresolved.
    public func overlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        paneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: false
        )
    }

    /// Resolves a pane's overlay rect in window-content coordinates (only the
    /// container y-offset is removed; the x-offset is preserved so the rect aligns
    /// with the window's content view).
    /// - Parameters:
    ///   - layoutSnapshot: the Bonsplit layout snapshot, if any.
    ///   - paneId: the pane to resolve, if any.
    /// - Returns: the window-content content rect, or `nil` when unresolved.
    public func windowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        paneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: true
        )
    }

    /// Picks the snapshot with renderable geometry, preferring the live snapshot.
    /// - Parameters:
    ///   - cachedSnapshot: the previously cached snapshot, if any.
    ///   - liveSnapshot: the freshly read live snapshot, if any.
    /// - Returns: the live snapshot when it has renderable geometry, otherwise the
    ///   cached snapshot when it does, otherwise whichever is non-nil.
    public func effectiveSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        if let liveSnapshot,
           Self.hasRenderableGeometry(liveSnapshot) {
            return liveSnapshot
        }
        if let cachedSnapshot,
           Self.hasRenderableGeometry(cachedSnapshot) {
            return cachedSnapshot
        }
        return cachedSnapshot ?? liveSnapshot
    }

    /// Whether a snapshot has a non-degenerate container and at least one
    /// non-degenerate pane.
    /// - Parameter snapshot: the snapshot to inspect.
    /// - Returns: `true` when the container and at least one pane exceed 1pt on
    ///   both axes.
    public static func hasRenderableGeometry(_ snapshot: LayoutSnapshot) -> Bool {
        snapshot.containerFrame.width > 1 &&
            snapshot.containerFrame.height > 1 &&
            snapshot.panes.contains { pane in
                pane.frame.width > 1 && pane.frame.height > 1
            }
    }

    /// Resolves the exact rectangle of a target view in the window's content-view
    /// coordinate space, used to align the overlay with the live AppKit view rather
    /// than the layout-snapshot pane rect.
    /// - Parameters:
    ///   - targetView: the terminal or browser view whose frame should be measured.
    ///   - contentView: the window content view the overlay is hosted in.
    /// - Returns: the target view's bounds converted into `contentView` coordinates,
    ///   or `nil` when the views are not in the same window, the target is detached,
    ///   or the converted rect is degenerate (≤ 1pt on either axis).
    public static func exactRect(
        for targetView: NSView,
        in contentView: NSView
    ) -> CGRect? {
        guard let contentWindow = contentView.window,
              let targetWindow = targetView.window,
              contentWindow === targetWindow,
              targetView.superview != nil else {
            return nil
        }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard rectInContent.width > 1, rectInContent.height > 1 else { return nil }
        return rectInContent
    }

    /// Chooses between the live exact rect and the layout-snapshot pane rect for the
    /// overlay, preferring the exact rect only when it fits inside the pane rect
    /// within a half-point tolerance.
    /// - Parameters:
    ///   - exactRect: the live view-derived rect, if any.
    ///   - paneRect: the layout-snapshot-derived pane rect, if any.
    /// - Returns: `exactRect` when it is non-degenerate and fits within `paneRect`;
    ///   otherwise `paneRect`; or `exactRect` when there is no `paneRect`.
    public static func preferredWindowOverlayRect(
        exactRect: CGRect?,
        paneRect: CGRect?
    ) -> CGRect? {
        guard let paneRect else { return exactRect }
        guard let exactRect,
              exactRect.width > 1,
              exactRect.height > 1 else {
            return paneRect
        }

        let tolerance: CGFloat = 0.5
        let exactFitsWithinPane =
            exactRect.minX >= paneRect.minX - tolerance &&
            exactRect.maxX <= paneRect.maxX + tolerance &&
            exactRect.minY >= paneRect.minY - tolerance &&
            exactRect.maxY <= paneRect.maxY + tolerance
        return exactFitsWithinPane ? exactRect : paneRect
    }
}

extension PixelRect {
    /// This rectangle expressed as a `CGRect`.
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
