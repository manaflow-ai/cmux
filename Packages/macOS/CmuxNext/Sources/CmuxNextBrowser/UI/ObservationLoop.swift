import AppKit
import CmuxNextDesign
import Observation

/// Re-runs `render` whenever any observable property it read changes.
/// Changes made in one main-actor turn coalesce into one render.
final class ObservationLoop {
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
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.arm() }
        }
    }
}

enum Motion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `changes` inside an animation context, or directly when Reduce
    /// Motion is on.
    static func animate(duration: TimeInterval = 0.18, _ changes: @escaping () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !reduced else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }
}

/// Backing for glass overlays that sit over web content. Glass alone picks
/// up the page's colors, which leaves text illegible on bright pages in dark
/// mode, so overlays add a neutral gray veil under their content.
final class OverlayBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.elevatedBackground.withAlphaComponent(0.64).cgColor
        }
    }
}
