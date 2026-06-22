import AppKit
import Bonsplit
import CmuxCanvas

extension ZoomableSplitRootView {
    struct SplitActionButtonHit {
        let paneId: PaneID
        let button: BonsplitConfiguration.SplitActionButton
    }

    private enum SplitActionLaneMetrics {
        static let reservedButtonWidth: CGFloat = 22
        static let spacing: CGFloat = 4
        static let leadingPadding: CGFloat = 6
        static let trailingPadding: CGFloat = 8

        static func laneWidth(buttonCount: Int) -> CGFloat {
            guard buttonCount > 0 else { return 0 }
            return leadingPadding
                + trailingPadding
                + CGFloat(buttonCount) * reservedButtonWidth
                + CGFloat(max(0, buttonCount - 1)) * spacing
        }
    }

    func canvasRect(from rect: CGRect) -> CanvasRect {
        CanvasRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    func canvasPoint(from point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: Double(point.x), y: Double(point.y))
    }

    func canvasSize(from size: CGSize) -> CanvasSize {
        CanvasSize(width: Double(size.width), height: Double(size.height))
    }

    func cgPoint(from point: CanvasPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    static func selectedPanelId(
        atDocumentPoint point: CGPoint,
        in snapshot: LayoutSnapshot,
        panelIdFromSurfaceId: (TabID) -> UUID?
    ) -> UUID? {
        for pane in snapshot.panes.reversed() {
            let paneFrame = CGRect(
                x: pane.frame.x - snapshot.containerFrame.x,
                y: pane.frame.y - snapshot.containerFrame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            guard paneFrame.contains(point) else { continue }
            guard let tabIdString = pane.selectedTabId ?? pane.tabIds.first,
                  let tabUUID = UUID(uuidString: tabIdString) else {
                return nil
            }
            return panelIdFromSurfaceId(TabID(uuid: tabUUID))
        }
        return nil
    }

    static func containsSplitDivider(atWindowPoint windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden else { return false }

        if let splitView = view as? NSSplitView {
            let pointInSplit = splitView.convert(windowPoint, from: nil)
            if splitView.bounds.contains(pointInSplit),
               splitDividerContains(pointInSplit, in: splitView) {
                return true
            }
        }

        for subview in view.subviews.reversed() {
            if containsSplitDivider(atWindowPoint: windowPoint, in: subview) {
                return true
            }
        }

        return false
    }

    static func splitActionButtonHit(
        atDocumentPoint point: CGPoint,
        in snapshot: LayoutSnapshot,
        appearance: BonsplitConfiguration.Appearance
    ) -> SplitActionButtonHit? {
        let buttons = appearance.splitButtons
        guard !buttons.isEmpty else { return nil }
        let tabBarHeight = appearance.tabBarHeight
        let laneWidth = SplitActionLaneMetrics.laneWidth(buttonCount: buttons.count)
        guard laneWidth > 0 else { return nil }

        for pane in snapshot.panes.reversed() {
            guard let paneUUID = UUID(uuidString: pane.paneId) else { continue }
            let paneFrame = CGRect(
                x: pane.frame.x - snapshot.containerFrame.x,
                y: pane.frame.y - snapshot.containerFrame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            guard paneFrame.contains(point),
                  point.y <= paneFrame.minY + tabBarHeight else {
                continue
            }

            let visibleLaneWidth = min(max(0, paneFrame.width), laneWidth)
            let laneMinX = paneFrame.maxX - visibleLaneWidth
            guard point.x >= laneMinX, point.x <= paneFrame.maxX else { return nil }

            let localPoint = CGPoint(x: point.x - laneMinX, y: point.y - paneFrame.minY)
            var buttonX = SplitActionLaneMetrics.leadingPadding
            for button in buttons {
                let buttonRect = CGRect(
                    x: buttonX,
                    y: 0,
                    width: SplitActionLaneMetrics.reservedButtonWidth,
                    height: tabBarHeight
                )
                if buttonRect.contains(localPoint) {
                    return SplitActionButtonHit(paneId: PaneID(id: paneUUID), button: button)
                }
                buttonX += SplitActionLaneMetrics.reservedButtonWidth + SplitActionLaneMetrics.spacing
            }
            return nil
        }
        return nil
    }

    static func pointTargetsPaneChrome(atDocumentPoint point: CGPoint, in snapshot: LayoutSnapshot) -> Bool {
        let tabBarHeight = WindowChromeMetrics.bonsplitTabBarHeight
        for pane in snapshot.panes.reversed() {
            let paneFrame = CGRect(
                x: pane.frame.x - snapshot.containerFrame.x,
                y: pane.frame.y - snapshot.containerFrame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            guard paneFrame.contains(point) else { continue }
            return point.y <= paneFrame.minY + tabBarHeight
        }
        return false
    }

    private static func splitDividerContains(_ point: NSPoint, in splitView: NSSplitView) -> Bool {
        let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
        guard dividerCount > 0 else { return false }

        for dividerIndex in 0..<dividerCount {
            let first = splitView.arrangedSubviews[dividerIndex].frame
            let second = splitView.arrangedSubviews[dividerIndex + 1].frame
            let thickness = splitView.dividerThickness
            let dividerRect: NSRect
            if splitView.isVertical {
                guard first.width > 1 || second.width > 1 else { continue }
                dividerRect = NSRect(
                    x: max(0, first.maxX),
                    y: 0,
                    width: thickness,
                    height: splitView.bounds.height
                )
            } else {
                guard first.height > 1 || second.height > 1 else { continue }
                dividerRect = NSRect(
                    x: 0,
                    y: max(0, first.maxY),
                    width: splitView.bounds.width,
                    height: thickness
                )
            }

            if dividerRect.insetBy(dx: -5, dy: -5).contains(point) {
                return true
            }
        }

        return false
    }

    func focusedPane(in snapshot: LayoutSnapshot) -> PaneGeometry? {
        guard let focusedPaneId = snapshot.focusedPaneId else { return nil }
        return snapshot.panes.first { $0.paneId == focusedPaneId }
    }
}
