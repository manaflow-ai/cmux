import AppKit

final class PortalSplitDividerRegion {
    weak var splitView: NSSplitView?
    weak var window: NSWindow?
    let dividerIndex: Int
    let rectInWindow: NSRect
    let boundsInWindow: NSRect
    let isVertical: Bool
    let isInHostedContent: Bool

    init(
        splitView: NSSplitView,
        dividerIndex: Int,
        rectInWindow: NSRect,
        boundsInWindow: NSRect,
        isVertical: Bool,
        isInHostedContent: Bool = false
    ) {
        self.splitView = splitView
        self.window = splitView.window
        self.dividerIndex = dividerIndex
        self.rectInWindow = rectInWindow
        self.boundsInWindow = boundsInWindow
        self.isVertical = isVertical
        self.isInHostedContent = isInHostedContent
    }

    var isLive: Bool {
        guard let splitView,
              let window,
              splitView.window === window,
              dividerIndex + 1 < splitView.arrangedSubviews.count,
              splitView.isVertical == isVertical else {
            return false
        }
        var current: NSView? = splitView
        while let view = current {
            if view.isHidden { return false }
            current = view.superview
        }
        let first = splitView.arrangedSubviews[dividerIndex].frame
        let second = splitView.arrangedSubviews[dividerIndex + 1].frame
        if isVertical {
            return first.width > 1 || second.width > 1
        }
        return first.height > 1 || second.height > 1
    }

    static func allLive(_ regions: [PortalSplitDividerRegion]) -> Bool {
        regions.allSatisfy(\.isLive)
    }

    static func collect(in rootView: NSView, hostView: NSView? = nil) -> (regions: [PortalSplitDividerRegion], observedViews: [NSView]) {
        var regions: [PortalSplitDividerRegion] = []
        var observedViews: [NSView] = []
        collect(in: rootView, hostView: hostView, ancestorHidden: false, into: &regions, observedViews: &observedViews)
        return (regions, observedViews)
    }

    private static func collect(
        in view: NSView,
        hostView: NSView?,
        ancestorHidden: Bool,
        into result: inout [PortalSplitDividerRegion],
        observedViews: inout [NSView]
    ) {
        observedViews.append(view)
        let isHidden = ancestorHidden || view.isHidden

        if !isHidden, let splitView = view as? NSSplitView {
            let splitBoundsInWindow = splitView.convert(splitView.bounds, to: nil)
            let dividerCount = max(0, splitView.arrangedSubviews.count - 1)
            for dividerIndex in 0..<dividerCount {
                let first = splitView.arrangedSubviews[dividerIndex].frame
                let second = splitView.arrangedSubviews[dividerIndex + 1].frame
                let thickness = splitView.dividerThickness
                let dividerRect: NSRect
                if splitView.isVertical {
                    guard first.width > 1 || second.width > 1 else { continue }
                    let x = max(0, first.maxX)
                    dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
                } else {
                    guard first.height > 1 || second.height > 1 else { continue }
                    let y = max(0, first.maxY)
                    dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
                }
                let dividerRectInWindow = splitView.convert(dividerRect, to: nil)
                guard dividerRectInWindow.width > 0, dividerRectInWindow.height > 0 else { continue }
                result.append(PortalSplitDividerRegion(
                    splitView: splitView,
                    dividerIndex: dividerIndex,
                    rectInWindow: dividerRectInWindow,
                    boundsInWindow: splitBoundsInWindow,
                    isVertical: splitView.isVertical,
                    isInHostedContent: hostView.map { splitView.isDescendant(of: $0) } ?? false
                ))
            }
        }

        for subview in view.subviews {
            collect(in: subview, hostView: hostView, ancestorHidden: isHidden, into: &result, observedViews: &observedViews)
        }
    }
}
