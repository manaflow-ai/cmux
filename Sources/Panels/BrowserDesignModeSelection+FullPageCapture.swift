import AppKit
import CmuxBrowser

extension BrowserDesignModeSelection {
    func documentCaptureRect(webViewBounds: NSRect) -> NSRect {
        let values = [
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
            viewport.width,
            viewport.height,
            viewport.scrollX,
            viewport.scrollY,
            webViewBounds.width,
            webViewBounds.height,
        ]
        guard values.allSatisfy(\.isFinite),
              bounds.width > 0,
              bounds.height > 0,
              viewport.width > 0,
              viewport.height > 0,
              webViewBounds.width > 0,
              webViewBounds.height > 0 else { return .zero }
        let scaleX = webViewBounds.width / viewport.width
        let scaleY = webViewBounds.height / viewport.height
        return NSRect(
            x: webViewBounds.minX + (bounds.x + viewport.scrollX) * scaleX,
            y: webViewBounds.minY + (bounds.y + viewport.scrollY) * scaleY,
            width: bounds.width * scaleX,
            height: bounds.height * scaleY
        )
    }

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
