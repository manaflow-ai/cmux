#if canImport(UIKit)
import CMUXMobileCore
import UIKit

/// Receives browser input translated into page-point wire values.
@MainActor
protocol BrowserStreamContentViewDelegate: AnyObject {
    func browserStreamContentView(_ view: BrowserStreamContentView, didProducePointer input: MobileBrowserPointerInput)
    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceScroll input: MobileBrowserScrollInput)
    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceKey input: MobileBrowserKeyInput)
    func browserStreamContentView(_ view: BrowserStreamContentView, didProduceText input: MobileBrowserTextInput)
    func browserStreamContentView(_ view: BrowserStreamContentView, didChangeViewport viewport: MobileBrowserViewport)
}
#endif
