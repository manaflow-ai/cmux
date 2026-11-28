public import AppKit
import CmuxNextDesign

/// App supplies pane facts; the layout owner converts predicted pane bounds to New Tab content.
@MainActor
public protocol NewTabPaneGeometrySource: AnyObject {
    var newTabPaneView: NSView { get }
    var newTabLayout: LayoutRootView? { get }
    var newTabHidesTabBar: Bool { get }
    var layoutPaneID: PaneID { get }
}

extension NewTabPaneGeometrySource {
    public var newTabContentSize: CGSize {
        contentSize(in: newTabPaneView.bounds.size)
    }

    public func newTabSplitContentSize(zone: PaneDropZone) -> CGSize? {
        newTabLayout?.newSplitPaneSize(splitting: layoutPaneID, zone: zone).map(contentSize)
    }

    public func newTabDividerContentSize(split: SplitID, ratio: Double) -> CGSize? {
        newTabLayout?.newDividerPaneSize(splitting: split, ratio: ratio).map(contentSize)
    }

    /// The keyboard's two split directions and its nearest Insert New divider, in stable order.
    /// Rust deduplicates these exact sizes and caps the parked renderer's work.
    public var newTabPrefetchContentSizes: [CGSize] {
        var sizes = [PaneDropZone.right, .bottom].compactMap { newTabSplitContentSize(zone: $0) }
        if let split = newTabLayout?.model.divider(beside: layoutPaneID),
           let size = newTabDividerContentSize(split: split, ratio: DividerInsertPlan.dividerRatio) {
            sizes.append(size)
        }
        return sizes
    }

    private func contentSize(in size: CGSize) -> CGSize {
        let scale = newTabPaneView.window?.backingScaleFactor ?? 2
        let strip = newTabHidesTabBar ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        return CGSize(width: size.width, height: max(0, size.height - strip))
    }
}
