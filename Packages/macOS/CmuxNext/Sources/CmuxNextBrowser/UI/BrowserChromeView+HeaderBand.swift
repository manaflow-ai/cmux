public import AppKit
public import CmuxNextDesign

// R109 `tabs.barOrder` below the toolbar: an empty band under the toolbar
// rows that the pane pins its tab strip to (`PaneHeaderBandHosting`).
extension BrowserChromeView: PaneHeaderBandHosting {
    public func setPaneHeaderBandHeight(_ height: CGFloat) {}

    public var paneHeaderBandGuide: NSLayoutGuide { headerBand.guide }

    public var paneHeaderBandRect: CGRect { .zero }

    public var onPaneHeaderBandRelease: (() -> Void)? {
        get { headerBand.onRelease }
        set { headerBand.onRelease = newValue }
    }

    public var paneHeaderAccessibilityElements: [Any] { [] }

    public var paneContentAccessibilityElements: [Any] { [] }
}

/// The band's guide, height constraint and release callback.
final class BrowserHeaderBand {
    let guide = NSLayoutGuide()
    var height: NSLayoutConstraint?
    var onRelease: (() -> Void)?
}
