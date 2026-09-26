#if canImport(UIKit)
import Testing
import UIKit
@testable import CmuxMobileBrowserStream

@MainActor
struct BrowserStreamContentViewDisplayLinkTests {
    @Test func displayLinkRunsOnlyWhileAttachedToAWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = BrowserStreamContentView(frame: window.bounds)
        #expect(view.displayLink == nil)

        window.addSubview(view)
        let attachedLink = view.displayLink
        #expect(attachedLink != nil)

        view.removeFromSuperview()
        #expect(view.displayLink == nil)

        window.addSubview(view)
        #expect(view.displayLink != nil)
        #expect(view.displayLink !== attachedLink)
        view.removeFromSuperview()
    }

    @Test func detachedViewDeallocates() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        weak var weakView: BrowserStreamContentView?
        autoreleasepool {
            let view = BrowserStreamContentView(frame: window.bounds)
            weakView = view
            window.addSubview(view)
            view.removeFromSuperview()
        }
        #expect(weakView == nil)
    }
}
#endif
