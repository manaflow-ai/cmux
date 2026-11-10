#if os(iOS)
import CmuxScreenKit
import SwiftUI
import UIKit

/// Connects the trackpad overlay's pad to the screen it drives. `ScreenView`
/// fills in the controller; the pad sends its touches through it, so the pad
/// and the screen share one pointer, one click state and one cursor.
@MainActor
public final class ScreenTrackpadLink {
    weak var controller: ScreenViewController?

    public init() {}
}

/// The trackpad overlay's surface: one finger moves the Mac's pointer the
/// way a MacBook trackpad does (a tap clicks, tap then drag drags, a long
/// press drags), two fingers tap to right-click and drag to scroll.
struct ScreenTrackpadPad: UIViewRepresentable {
    let link: ScreenTrackpadLink

    func makeUIView(context: Context) -> ScreenTrackpadPadView {
        let view = ScreenTrackpadPadView()
        view.link = link
        return view
    }

    func updateUIView(_ view: ScreenTrackpadPadView, context: Context) {
        view.link = link
    }
}

final class ScreenTrackpadPadView: UIView, UIGestureRecognizerDelegate {
    weak var link: ScreenTrackpadLink?
    private let finger = SingleTouchRecognizer(target: nil, action: nil)
    private let twoFingerTap = UITapGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "screen.trackpad.pad"
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Move one finger to move the pointer, tap to click."
        accessibilityTraits = .allowsDirectInteraction
        finger.onEvent = { [weak self] event in self?.link?.controller?.padTouch(event) }
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan(_:)))
        // Fingers and the pencil, as on the screen; an iPad mouse drives the screen itself.
        let touches = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        for recognizer in [finger, twoFingerTap, twoFingerPan] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = touches
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTwoFingerTap() {
        link?.controller?.padRightClick()
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        link?.controller?.padScroll(by: translation, began: recognizer.state == .began)
    }
}

/// Where the trackpad overlay sits: an offset from its home at the bottom
/// centre, kept inside the screen so its grip can always be reached.
struct TrackpadOverlayPlacement: Equatable {
    var offset: CGSize = .zero

    /// `proposed` clamped so a `panel`-sized overlay at the bottom centre of
    /// `container` (inside `margin`) stays fully on screen.
    static func clamped(_ proposed: CGSize, panel: CGSize, container: CGSize, margin: CGFloat) -> CGSize {
        let maxX = max(0, (container.width - panel.width) / 2 - margin)
        let maxUp = max(0, container.height - panel.height - 2 * margin)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxUp), 0))
    }
}
#endif
