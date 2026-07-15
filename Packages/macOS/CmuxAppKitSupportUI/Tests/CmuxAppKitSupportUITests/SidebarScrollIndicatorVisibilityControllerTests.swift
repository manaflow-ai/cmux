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

    let resolved = await withCheckedContinuation { continuation in
      resolver.onResolve = { resolved in
        resolver.onResolve = nil
        continuation.resume(returning: resolved)
      }
      resolver.resolveScrollView()
    }

    #expect(resolved === scrollView)
  }

  @MainActor
  @Test func resolverFailsClosedForAmbiguousSiblingScrollViews() async {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    let resolverHost = NSView(frame: NSRect(x: 120, y: 336, width: 0, height: 0))
    let resolver = SidebarScrollViewResolverView(frame: .zero)
    let firstScrollView = NSScrollView(frame: root.bounds)
    let secondScrollView = NSScrollView(frame: root.bounds)
    resolverHost.addSubview(resolver)
    root.addSubview(resolverHost)
    root.addSubview(firstScrollView)
    root.addSubview(secondScrollView)

    let resolved = await withCheckedContinuation { continuation in
      resolver.onResolve = { resolved in
        resolver.onResolve = nil
        continuation.resume(returning: resolved)
      }
      resolver.resolveScrollView()
    }

    #expect(resolved == nil)
  }

  @MainActor
  @Test func resolverRevalidatesSiblingResolutionAcrossUpdates() async {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
    let resolverHost = NSView(frame: NSRect(x: 120, y: 336, width: 0, height: 0))
    let resolver = SidebarScrollViewResolverView(frame: .zero)
    let scrollView = NSScrollView(frame: root.bounds)
    resolverHost.addSubview(resolver)
    root.addSubview(resolverHost)
    root.addSubview(scrollView)

    let firstResolution = await resolve(using: resolver)
    #expect(firstResolution === scrollView)

    root.addSubview(NSScrollView(frame: root.bounds))
    let revalidatedResolution = await resolve(using: resolver)
    #expect(revalidatedResolution == nil)
  }

  @MainActor
  @Test func controllerUsesInteractiveNativeScrollerAndShowsWhenPositionChanges() async throws {
    let center = NotificationCenter()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center
    )
    scrollView.layoutSubtreeIfNeeded()
    let indicator = try #require(controller.indicatorScroller)

    #expect(indicator.isHidden)
    #expect(indicator.alphaValue == 0)

    scrollView.contentView.scroll(to: CGPoint(x: 0, y: 100))
    center.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    await waitUntil { !indicator.isHidden }

    #expect(!indicator.isHidden)
    #expect(indicator.isEnabled)
    #expect(indicator.target === scrollView)
    #expect(indicator.action != nil)
    _ = controller
  }

  @MainActor
  @Test func controllerHidesAfterFadeCompletes() async throws {
    let center = NotificationCenter()
    var fadeCompletions: [@MainActor () -> Void] = []
    let scrollView = makeScrollableScrollView()
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center,
      sleep: { _ in },
      fadeDuration: 0,
      fadeAnimator: { scroller, _, completion in
        scroller.alphaValue = 0
        fadeCompletions.append(completion)
      }
    )
    let indicator = try #require(controller.indicatorScroller)

    scroll(to: 100, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 1 }
    fadeCompletions[0]()

    #expect(indicator.isHidden)
    #expect(indicator.alphaValue == 0)
    _ = controller
  }

  @MainActor
  @Test func newScrollInvalidatesOlderFadeCompletion() async throws {
    let center = NotificationCenter()
    var fadeCompletions: [@MainActor () -> Void] = []
    let scrollView = makeScrollableScrollView()
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center,
      sleep: { _ in },
      fadeDuration: 0,
      fadeAnimator: { scroller, _, completion in
        scroller.alphaValue = 0
        fadeCompletions.append(completion)
      }
    )
    let indicator = try #require(controller.indicatorScroller)

    scroll(to: 100, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 1 }
    scroll(to: 200, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 2 }

    fadeCompletions[0]()
    #expect(!indicator.isHidden)

    fadeCompletions[1]()
    #expect(indicator.isHidden)
    _ = controller
  }

  @MainActor
  @Test func pointerHoverDefersFadeUntilExit() async throws {
    let center = NotificationCenter()
    var fadeCompletions: [@MainActor () -> Void] = []
    let scrollView = makeScrollableScrollView()
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center,
      sleep: { _ in },
      fadeDuration: 0,
      fadeAnimator: { scroller, _, completion in
        scroller.alphaValue = 0
        fadeCompletions.append(completion)
      }
    )
    let indicator = try #require(controller.indicatorScroller)

    scroll(to: 100, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 1 }
    controller.handleIndicatorPointerPresenceChanged(true)
    fadeCompletions[0]()

    #expect(!indicator.isHidden)
    #expect(indicator.alphaValue == 1)

    controller.handleIndicatorPointerPresenceChanged(false)
    await waitUntil { fadeCompletions.count == 2 }
    fadeCompletions[1]()

    #expect(indicator.isHidden)
    #expect(indicator.alphaValue == 0)
  }

  @MainActor
  @Test func dragOutsideScrollerDefersFadeUntilMouseUp() async throws {
    let center = NotificationCenter()
    var fadeCompletions: [@MainActor () -> Void] = []
    let scrollView = makeScrollableScrollView()
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center,
      sleep: { _ in },
      fadeDuration: 0,
      fadeAnimator: { scroller, _, completion in
        scroller.alphaValue = 0
        fadeCompletions.append(completion)
      }
    )
    let indicator = try #require(controller.indicatorScroller)

    scroll(to: 100, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 1 }
    controller.handleIndicatorPointerPresenceChanged(true)
    controller.handleIndicatorInteractionChanged(true)
    controller.handleIndicatorPointerPresenceChanged(false)
    fadeCompletions[0]()

    #expect(!indicator.isHidden)
    #expect(indicator.alphaValue == 1)
    #expect(fadeCompletions.count == 1)

    controller.handleIndicatorInteractionChanged(false)
    await waitUntil { fadeCompletions.count == 2 }
    fadeCompletions[1]()

    #expect(indicator.isHidden)
    #expect(indicator.alphaValue == 0)
  }

  @MainActor
  @Test func replacingScrollerInvalidatesOldHoverAndFadeState() async throws {
    let center = NotificationCenter()
    var fadeCompletions: [@MainActor () -> Void] = []
    let scrollView = makeScrollableScrollView()
    let controller = SidebarScrollIndicatorVisibilityController(
      scrollView: scrollView,
      notificationCenter: center,
      sleep: { _ in },
      fadeDuration: 0,
      fadeAnimator: { scroller, _, completion in
        scroller.alphaValue = 0
        fadeCompletions.append(completion)
      }
    )

    scroll(to: 100, in: scrollView, notificationCenter: center)
    await waitUntil { fadeCompletions.count == 1 }
    controller.handleIndicatorPointerPresenceChanged(true)

    scrollView.verticalScroller = NSScroller()
    controller.synchronizeIndicator()
    let replacement = try #require(controller.indicatorScroller)
    fadeCompletions[0]()

    #expect(!replacement.isHidden)
    await waitUntil { fadeCompletions.count == 2 }
    fadeCompletions[1]()

    #expect(replacement.isHidden)
    #expect(replacement.alphaValue == 0)
  }

  @MainActor
  private func makeScrollableScrollView() -> NSScrollView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
    scrollView.layoutSubtreeIfNeeded()
    return scrollView
  }

  @MainActor
  private func scroll(
    to y: CGFloat,
    in scrollView: NSScrollView,
    notificationCenter: NotificationCenter
  ) {
    scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
    notificationCenter.post(
      name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  @MainActor
  private func resolve(using resolver: SidebarScrollViewResolverView) async -> NSScrollView? {
    await withCheckedContinuation { continuation in
      resolver.onResolve = { resolved in
        resolver.onResolve = nil
        continuation.resume(returning: resolved)
      }
      resolver.resolveScrollView()
    }
  }

  @MainActor
  private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !predicate(), clock.now < deadline {
      await Task.yield()
    }
  }
}
