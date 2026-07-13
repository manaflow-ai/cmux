import AppKit
import QuartzCore

/// Owns the sidebar's scroll indicator independently of AppKit's native
/// scroller preference and layout lifecycle.
@MainActor
final class SidebarScrollIndicatorVisibilityController {
    private static let fadeDelay: Duration = .seconds(1)
    private static let fadeDuration: TimeInterval = 0.35

    private weak var scrollView: NSScrollView?
    let indicatorView: SidebarScrollIndicatorView
    private let notificationCenter: NotificationCenter
    private var fadeTask: Task<Void, Never>?
    private var fadeGeneration = 0
    private var lastContentOrigin: CGPoint
    // Main-actor-owned until deinit, where removing the now-unreachable
    // controller's observer tokens is safe from the nonisolated destructor.
    private nonisolated(unsafe) var observerTokens: [any NSObjectProtocol] = []

    init(scrollView: NSScrollView, notificationCenter: NotificationCenter = .default) {
        self.scrollView = scrollView
        self.notificationCenter = notificationCenter
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
        fadeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.fadeDelay)
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

@MainActor
final class SidebarScrollIndicatorView: NSView {
    private static let minimumKnobHeight: CGFloat = 24

    private weak var scrollView: NSScrollView?
    private let knobLayer = CALayer()

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(knobLayer)
        knobLayer.cornerRadius = 3
        alphaValue = 0
        isHidden = true
        updateKnobColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateKnobColor()
    }

    @discardableResult
    func updateGeometry() -> Bool {
        guard let scrollView,
              let documentView = scrollView.documentView else { return false }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let trackHeight = bounds.height
        let maximumOffset = documentHeight - viewportHeight
        guard viewportHeight > 0, trackHeight > 0, maximumOffset > 1 else { return false }

        let knobHeight = min(
            trackHeight,
            max(Self.minimumKnobHeight, trackHeight * viewportHeight / documentHeight)
        )
        let rawOffset = scrollView.contentView.bounds.minY
        let progress = min(max(rawOffset / maximumOffset, 0), 1)
        let visualProgress = documentView.isFlipped ? progress : 1 - progress
        let knobY = (1 - visualProgress) * (trackHeight - knobHeight)
        knobLayer.frame = CGRect(x: 0, y: knobY, width: bounds.width, height: knobHeight)
        return true
    }

    private func updateKnobColor() {
        knobLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7).cgColor
    }
}

@MainActor
enum SidebarScrollIndicatorVisibilityControllers {
    private static let controllers = NSMapTable<NSScrollView, SidebarScrollIndicatorVisibilityController>
        .weakToStrongObjects()

    static func attach(to scrollView: NSScrollView) {
        if let controller = controllers.object(forKey: scrollView) {
            controller.synchronizeIndicator()
            return
        }
        controllers.setObject(
            SidebarScrollIndicatorVisibilityController(scrollView: scrollView),
            forKey: scrollView
        )
    }
}
