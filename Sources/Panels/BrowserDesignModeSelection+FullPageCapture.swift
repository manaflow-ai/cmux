import AppKit
import CmuxBrowser

extension BrowserDesignModeSelection {
    func fullPageCaptureRect(imageSize: NSSize) -> NSRect {
        let values = [
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
            viewport.scrollX,
            viewport.scrollY,
            imageSize.width,
            imageSize.height,
        ]
        guard values.allSatisfy(\.isFinite),
              bounds.width > 0,
              bounds.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else { return .zero }
        return NSRect(
            x: bounds.x + viewport.scrollX,
            y: imageSize.height - bounds.y - viewport.scrollY - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }
}
