import AppKit
import Bonsplit

enum BrowserPaneDropRouting {
    static func zone(for location: CGPoint, in size: CGSize, topChromeHeight: CGFloat = 0) -> DropZone {
        PaneDropRouting.zone(for: location, in: size, topChromeHeight: topChromeHeight)
    }

    static func overlayFrame(for zone: DropZone, in size: CGSize, topChromeHeight: CGFloat = 0) -> CGRect {
        PaneDropRouting.compactOverlayFrame(for: zone, in: size, topChromeHeight: topChromeHeight)
    }

}
