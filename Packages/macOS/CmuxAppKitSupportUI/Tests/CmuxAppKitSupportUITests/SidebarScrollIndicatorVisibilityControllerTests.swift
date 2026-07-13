import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct SidebarScrollIndicatorVisibilityControllerTests {
    @MainActor
    @Test func resolverFindsSwiftUIHostingScrollViewSibling() async {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        let resolverHost = NSView(frame: NSRect(x: 120, y: 336, width: 0, height: 0))
        let resolver = SidebarScrollViewResolverView(frame: .zero)
        let scrollContainer = NSView(frame: root.bounds)
        let scrollView = NSScrollView(frame: scrollContainer.bounds)
        scrollContainer.addSubview(scrollView)
        resolverHost.addSubview(resolver)
        root.addSubview(resolverHost)
        root.addSubview(scrollContainer)

        var resolved: NSScrollView?
        resolver.onResolve = { resolved = $0 }
        resolver.resolveScrollView()
        await Task.yield()

        #expect(resolved === scrollView)
    }

    @MainActor
    @Test func controllerHidesAtRestAndShowsWhenScrollPositionChanges() async throws {
        let center = NotificationCenter()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        let controller = SidebarScrollIndicatorVisibilityController(
            scrollView: scrollView,
            notificationCenter: center
        )
        scrollView.layoutSubtreeIfNeeded()
        let indicator = controller.indicatorView

        #expect(indicator.isHidden)
        #expect(indicator.alphaValue == 0)

        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 100))
        center.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        await Task.yield()

        #expect(!indicator.isHidden)
        _ = controller
    }
}
