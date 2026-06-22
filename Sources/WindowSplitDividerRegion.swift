import AppKit

struct WindowSplitDividerRegion {
    let rectInWindow: NSRect
    let splitBoundsInWindow: NSRect
    let isVertical: Bool
    let isInHostedContent: Bool
    weak var splitView: NSSplitView?
    let dividerIndex: Int
}
