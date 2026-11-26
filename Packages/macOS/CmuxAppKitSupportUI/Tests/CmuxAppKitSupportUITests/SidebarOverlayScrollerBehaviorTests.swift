import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct SidebarOverlayScrollerBehaviorTests {
  @MainActor
  @Test func fittingContentHidesNativeScroller() throws {
    let scrollView = makeScrollView(documentHeight: 200)

    scrollView.applySidebarOverlayScrollerConfiguration()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let scroller = try #require(scrollView.verticalScroller)
    #expect(scroller.isHidden)
  }

  @MainActor
  @Test func overflowingContentKeepsNativeScrollerInteractive() throws {
    let scrollView = makeScrollView(documentHeight: 800)

    scrollView.applySidebarOverlayScrollerConfiguration()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let scroller = try #require(scrollView.verticalScroller)
    #expect(scroller.isEnabled)
    #expect(scroller.target === scrollView)
    #expect(scroller.action != nil)
  }

  @MainActor
  private func makeScrollView(documentHeight: CGFloat) -> NSScrollView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    scrollView.documentView = NSView(
      frame: NSRect(x: 0, y: 0, width: 200, height: documentHeight)
    )
    return scrollView
  }
}
