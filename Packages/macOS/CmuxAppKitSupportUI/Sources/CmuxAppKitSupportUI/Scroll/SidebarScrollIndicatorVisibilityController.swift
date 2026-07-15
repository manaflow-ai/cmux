import AppKit
import QuartzCore

/// Owns the sidebar's scroll indicator independently of AppKit's native
/// scroller preference and layout lifecycle.
@MainActor
final class SidebarScrollIndicatorVisibilityController {
  typealias FadeAnimator =
    @MainActor (
      _ scroller: NSScroller,
      _ duration: TimeInterval,
      _ completion: @escaping @MainActor () -> Void
    ) -> Void

  static var associationKey: UInt8 = 0

  private static let fadeDelay: Duration = .seconds(1)

  private weak var scrollView: NSScrollView?
  private(set) weak var indicatorScroller: NSScroller?
  private let notificationCenter: NotificationCenter
  private let sleep: @Sendable (Duration) async throws -> Void
  private let fadeDuration: TimeInterval
  private let fadeAnimator: FadeAnimator
  private var fadeTask: Task<Void, Never>?
  private var fadeGeneration = 0
  private var indicatorIsActive = false
  private var indicatorInteractionIsActive = false
  private var pointerIsOverIndicator = false
  private var lastContentOrigin: CGPoint
  // Main-actor-owned until deinit, where removing the now-unreachable
  // controller's observer tokens is safe from the nonisolated destructor.
  private nonisolated(unsafe) var observerTokens: [any NSObjectProtocol] = []

  init(
    scrollView: NSScrollView,
    notificationCenter: NotificationCenter = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await ContinuousClock().sleep(for: duration)
    },
    fadeDuration: TimeInterval = 0.35,
    fadeAnimator: @escaping FadeAnimator = { scroller, duration, completion in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scroller.animator().alphaValue = 0
      } completionHandler: {
        Task { @MainActor in completion() }
      }
    }
  ) {
    self.scrollView = scrollView
    self.notificationCenter = notificationCenter
    self.sleep = sleep
    self.fadeDuration = fadeDuration
    self.fadeAnimator = fadeAnimator
    self.lastContentOrigin = scrollView.contentView.bounds.origin

    synchronizeIndicator()
    observeScrollView()
  }

  deinit {
    fadeTask?.cancel()
    for token in observerTokens {
      notificationCenter.removeObserver(token)
    }
  }

  func synchronizeIndicator() {
    guard let scrollView else { return }
    var configurationChanged = false
    if scrollView.hasHorizontalScroller {
      scrollView.hasHorizontalScroller = false
      configurationChanged = true
    }
    if scrollView.scrollerStyle != .overlay {
      scrollView.scrollerStyle = .overlay
      configurationChanged = true
    }
    if scrollView.autohidesScrollers {
      scrollView.autohidesScrollers = false
      configurationChanged = true
    }
    if !scrollView.hasVerticalScroller {
      scrollView.hasVerticalScroller = true
      configurationChanged = true
    }
    let nativeScroller = scrollView.verticalScroller
    let scroller: SidebarInteractiveScroller
    if let interactiveScroller = nativeScroller as? SidebarInteractiveScroller {
      scroller = interactiveScroller
    } else {
      scroller = SidebarInteractiveScroller(frame: nativeScroller?.frame ?? .zero)
      scroller.controlSize = nativeScroller?.controlSize ?? .regular
      scroller.knobStyle = nativeScroller?.knobStyle ?? .default
      scrollView.verticalScroller = scroller
      configurationChanged = true
    }
    let scrollerChanged = indicatorScroller !== scroller
    if configurationChanged || scrollerChanged {
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    if scrollerChanged {
      fadeTask?.cancel()
      fadeTask = nil
      fadeGeneration &+= 1
      indicatorInteractionIsActive = false
      pointerIsOverIndicator = false
      if let previousScroller = indicatorScroller as? SidebarInteractiveScroller {
        previousScroller.onPointerPresenceChanged = nil
        previousScroller.onInteractionChanged = nil
      }
      indicatorScroller = scroller
      scroller.onPointerPresenceChanged = { [weak self] isPresent in
        self?.handleIndicatorPointerPresenceChanged(isPresent)
      }
      scroller.onInteractionChanged = { [weak self] isActive in
        self?.handleIndicatorInteractionChanged(isActive)
      }
      applyIndicatorState(to: scroller)
      if indicatorIsActive {
        scheduleIndicatorFade()
      }
    } else if !indicatorIsActive, !scroller.isHidden {
      scroller.alphaValue = 0
      scroller.isHidden = true
    }
  }

  private func observeScrollView() {
    guard let scrollView else { return }
    let contentView = scrollView.contentView
    contentView.postsBoundsChangedNotifications = true
    observerTokens.append(
      notificationCenter.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: contentView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleScrollPositionChange()
        }
      }
    )
    observerTokens.append(
      notificationCenter.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        // Run after AppKit's synchronous per-scroll-view preference
        // reset regardless of observer registration order.
        Task { @MainActor [weak self] in
          self?.synchronizeIndicator()
        }
      }
    )
  }

  private func handleScrollPositionChange() {
    guard let currentOrigin = scrollView?.contentView.bounds.origin,
      currentOrigin != lastContentOrigin
    else { return }
    lastContentOrigin = currentOrigin
    showThenFadeIndicator()
  }

  private func showThenFadeIndicator() {
    showIndicator()
    scheduleIndicatorFade()
  }

  private func showIndicator() {
    guard let scrollView,
      let documentView = scrollView.documentView,
      documentView.bounds.height - scrollView.contentView.bounds.height > 1,
      let indicatorScroller
    else {
      hideIndicatorImmediately()
      return
    }
    fadeGeneration &+= 1
    indicatorIsActive = true
    scrollView.reflectScrolledClipView(scrollView.contentView)
    indicatorScroller.isHidden = false
    indicatorScroller.layer?.removeAllAnimations()
    indicatorScroller.alphaValue = 1
  }

  private func scheduleIndicatorFade() {
    guard indicatorIsActive else { return }
    fadeTask?.cancel()
    let sleep = sleep
    fadeTask = Task { @MainActor [weak self, sleep] in
      do {
        try await sleep(Self.fadeDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.fadeIndicator()
    }
  }

  private func fadeIndicator() {
    guard indicatorIsActive,
      !indicatorInteractionIsActive,
      !pointerIsOverIndicator,
      let indicatorScroller
    else { return }
    fadeGeneration &+= 1
    let generation = fadeGeneration
    fadeAnimator(indicatorScroller, fadeDuration) { [weak self, weak indicatorScroller] in
      guard let self,
        self.fadeGeneration == generation,
        let indicatorScroller
      else { return }
      self.indicatorIsActive = false
      indicatorScroller.isHidden = true
    }
  }

  private func hideIndicatorImmediately() {
    fadeTask?.cancel()
    fadeGeneration &+= 1
    indicatorIsActive = false
    indicatorInteractionIsActive = false
    pointerIsOverIndicator = false
    guard let indicatorScroller else { return }
    indicatorScroller.layer?.removeAllAnimations()
    indicatorScroller.alphaValue = 0
    indicatorScroller.isHidden = true
  }

  private func applyIndicatorState(to scroller: NSScroller) {
    scroller.layer?.removeAllAnimations()
    scroller.alphaValue = indicatorIsActive ? 1 : 0
    scroller.isHidden = !indicatorIsActive
  }

  func handleIndicatorPointerPresenceChanged(_ isPresent: Bool) {
    if !isPresent {
      pointerIsOverIndicator = false
      if !indicatorInteractionIsActive {
        scheduleIndicatorFade()
      }
      return
    }
    guard indicatorIsActive, let indicatorScroller else { return }
    pointerIsOverIndicator = true
    fadeTask?.cancel()
    fadeGeneration &+= 1
    indicatorScroller.layer?.removeAllAnimations()
    indicatorScroller.alphaValue = 1
    indicatorScroller.isHidden = false
  }

  func handleIndicatorInteractionChanged(_ isActive: Bool) {
    indicatorInteractionIsActive = isActive
    if isActive {
      guard indicatorIsActive, let indicatorScroller else { return }
      fadeTask?.cancel()
      fadeGeneration &+= 1
      indicatorScroller.layer?.removeAllAnimations()
      indicatorScroller.alphaValue = 1
      indicatorScroller.isHidden = false
    } else if !pointerIsOverIndicator {
      scheduleIndicatorFade()
    }
  }
}
