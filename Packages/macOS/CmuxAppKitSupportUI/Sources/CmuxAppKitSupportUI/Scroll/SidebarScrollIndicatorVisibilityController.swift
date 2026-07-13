import AppKit
import QuartzCore

/// Owns the sidebar's scroll indicator independently of AppKit's native
/// scroller preference and layout lifecycle.
@MainActor
final class SidebarScrollIndicatorVisibilityController {
    static var associationKey: UInt8 = 0

    private static let fadeDelay: Duration = .seconds(1)
    private static let fadeDuration: TimeInterval = 0.35

    private weak var scrollView: NSScrollView?
    let indicatorView: SidebarScrollIndicatorView
    private let notificationCenter: NotificationCenter
    private let sleep: @Sendable (Duration) async throws -> Void
    private var fadeTask: Task<Void, Never>?
    private var fadeGeneration = 0
    private var lastContentOrigin: CGPoint
    // Main-actor-owned until deinit, where removing the now-unreachable
    // controller's observer tokens is safe from the nonisolated destructor.
    private nonisolated(unsafe) var observerTokens: [any NSObjectProtocol] = []

    init(
        scrollView: NSScrollView,
        notificationCenter: NotificationCenter = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.scrollView = scrollView
        self.notificationCenter = notificationCenter
        self.sleep = sleep
        self.indicatorView = SidebarScrollIndicatorView(scrollView: scrollView)
        self.lastContentOrigin = scrollView.contentView.bounds.origin

        installIndicator(in: scrollView)
        observeScrollPosition()
    }

    deinit {
        fadeTask?.cancel()
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    func synchronizeIndicator() {
        guard let scrollView else { return }
        if indicatorView.superview !== scrollView {
            installIndicator(in: scrollView)
        }
        updateIndicatorFrame(in: scrollView)
        indicatorView.updateGeometry()
    }

    private func installIndicator(in scrollView: NSScrollView) {
        indicatorView.removeFromSuperview()
        scrollView.addSubview(indicatorView, positioned: .above, relativeTo: scrollView.contentView)
        indicatorView.autoresizingMask = [.minXMargin, .height]
        updateIndicatorFrame(in: scrollView)
        indicatorView.updateGeometry()
    }

    private func updateIndicatorFrame(in scrollView: NSScrollView) {
        let viewportFrame = scrollView.contentView.frame
        indicatorView.frame = CGRect(
            x: viewportFrame.maxX - 9,
            y: viewportFrame.minY + 3,
            width: 6,
            height: max(0, viewportFrame.height - 6)
        )
    }

    private func observeScrollPosition() {
        guard let scrollView else { return }
        let contentView = scrollView.contentView
        contentView.postsBoundsChangedNotifications = true
        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScrollPositionChange()
                }
            }
        )
    }

    private func handleScrollPositionChange() {
        guard let currentOrigin = scrollView?.contentView.bounds.origin,
              currentOrigin != lastContentOrigin else { return }
        lastContentOrigin = currentOrigin
        showThenFadeIndicator()
    }

    private func showThenFadeIndicator() {
        showIndicator()
        scheduleIndicatorFade()
    }

    private func showIndicator() {
        guard indicatorView.updateGeometry() else {
            indicatorView.isHidden = true
            return
        }
        fadeGeneration &+= 1
        indicatorView.isHidden = false
        indicatorView.layer?.removeAllAnimations()
        indicatorView.alphaValue = 1
    }

    private func scheduleIndicatorFade() {
        guard !indicatorView.isHidden else { return }
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
        guard !indicatorView.isHidden else { return }
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            indicatorView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                self.indicatorView.isHidden = true
            }
        }
    }
}
