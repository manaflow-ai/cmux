import AppKit
@testable import CmuxNextDesign
import Testing

/// Where the window overlay host puts an overlay (`WindowOverlayHost.origin(for:options:in:)`): 8 pt from the
/// edges when it fits, centered on an axis it does not fit (a dialog that fills the window sits edge to edge,
/// cmux#38299, instead of 8 pt off and over the far edge).
@Suite struct WindowOverlayOriginTests {
    private let bounds = NSRect(x: 0, y: 0, width: 1000, height: 700)

    @Test func aDialogThatFillsTheWindowSitsEdgeToEdge() {
        #expect(WindowOverlayHost.origin(for: bounds.size, options: .dialog(), in: bounds) == .zero)
        // Larger than the window on both axes: centered, overflowing both ends evenly.
        #expect(WindowOverlayHost.origin(for: NSSize(width: 1100, height: 800), options: .dialog(), in: bounds) == NSPoint(x: -50, y: -50))
    }

    @Test func aSmallDialogCentersAndAnEdgePopoverKeepsItsInset() {
        #expect(WindowOverlayHost.origin(for: NSSize(width: 400, height: 300), options: .dialog(), in: bounds) == NSPoint(x: 300, y: 200))
        let nearRight = OverlayOptions(kind: .popover, anchor: NSRect(x: 980, y: 400, width: 10, height: 10))
        #expect(WindowOverlayHost.origin(for: NSSize(width: 200, height: 100), options: nearRight, in: bounds) == NSPoint(x: 792, y: 296))
    }
}
