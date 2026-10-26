import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import Observation

/// Re-runs `render` whenever any observable property it read changes.
///
/// A change marks the loop dirty and asks for one main run loop pass; `render` runs once in that
/// pass's before-waiting stage, ahead of AppKit's display cycle and the Core Animation commit, so
/// every change of the pass shows in the frame it commits, after the input the pass dispatched.
/// This is Blink's model: a change only schedules a visual update
/// (`PageAnimator::ScheduleVisualUpdate`, third_party/blink/renderer/core/page/page_animator.cc),
/// and the lifecycle runs once before the next commit. An owner that has the app's scheduler uses
/// `FrameObservation` instead.
final class ObservationLoop {
    /// After the input-response pass, so a change it applies renders in the same pass; before
    /// AppKit's display cycle and the Core Animation commit (2,000,000).
    static let renderOrder: CFIndex = InputResponsePass.order + 1

    private let render: () -> Void
    private var isActive = true

    init(_ render: @escaping () -> Void) {
        self.render = render
        arm()
    }

    func cancel() {
        isActive = false
    }

    private func arm() {
        guard isActive else { return }
        let order = Self.renderOrder
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            MainRunLoopObserver.once(activities: .beforeWaiting, order: order) { [weak self] in self?.arm() }
            // An observer never wakes the run loop: without this, a change made after the render
            // stage (in AppKit's layout) would wait for the next unrelated event.
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

/// Backing for glass overlays that sit over web content. Glass alone picks
/// up the page's colors, which leaves text illegible on bright pages in dark
/// mode, so overlays add a neutral gray veil under their content. The
/// opaque Reduce Transparency fill needs no veil; it shows unchanged.
final class OverlayBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = enclosingOverlayMaterial == .opaque
                ? NSColor.clear.cgColor
                : Palette.elevatedBackground.withAlphaComponent(0.64).cgColor
        }
    }
}
