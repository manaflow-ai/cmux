#if os(iOS)
import CmuxScreenKit
import SwiftUI
import UIKit

/// Connects the trackpad drawer's pad to the screen it drives. `ScreenView`
/// fills in the controller; the pad sends its touches through it, so the pad
/// and the screen share one pointer, one click state and one cursor.
@MainActor @Observable
public final class ScreenTrackpadLink {
    @ObservationIgnored weak var controller: ScreenViewController?
    /// The size (framebuffer pixels) of the display the screen is fitted to:
    /// one display of several, or the whole frame. The trackpad's height
    /// leaves that display's fitted height to the screen.
    public internal(set) var focusSize = CGSize.zero
    /// How far the software keyboard (or only its key bar, with a hardware
    /// keyboard) reaches above the bottom of the safe area, in points; 0 while
    /// it is down. The trackpad sits under it, so that much less room is kept.
    public internal(set) var keyboardOverlap: CGFloat = 0
    /// A finger touched the pad since the viewer opened (the hint stops for good).
    public internal(set) var padTouched = false

    public init() {}
}

/// The trackpad drawer's surface: one finger moves the Mac's pointer the
/// way a MacBook trackpad does (a tap clicks, tap then drag drags, a long
/// press drags), two fingers tap to right-click and drag to scroll.
struct ScreenTrackpadPad: UIViewRepresentable {
    let link: ScreenTrackpadLink
    /// The drawer is open. Closed, the pad stays laid out under the handle but
    /// takes no touches and is hidden from VoiceOver and UI tests (SwiftUI's
    /// `accessibilityHidden` does not reach a hosted UIKit view).
    let active: Bool

    func makeUIView(context: Context) -> ScreenTrackpadPadView {
        let view = ScreenTrackpadPadView()
        view.link = link
        view.setActive(active)
        return view
    }

    func updateUIView(_ view: ScreenTrackpadPadView, context: Context) {
        view.link = link
        view.setActive(active)
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
        finger.onEvent = { [weak self] event in
            if case .down = event, self?.link?.padTouched == false { self?.link?.padTouched = true }
            self?.link?.controller?.padTouch(event)
        }
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

    func setActive(_ active: Bool) {
        isUserInteractionEnabled = active
        isAccessibilityElement = active
        accessibilityElementsHidden = !active
    }

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
/// Shows what the pad is each time a viewer opens with it up: a pointing
/// hand glides across it as if moving the pointer, then taps, twice over,
/// then fades. It only plays (the Mac's pointer does not move), never takes
/// touches, and its owner removes it at the first touch on the pad. Under
/// Reduce Motion a still hand shows instead, until that touch.
struct ScreenTrackpadHint: View {
    let reduceMotion: Bool
    /// The hint has played through: the owner stops drawing it.
    let finished: () -> Void
    @State private var progress = 0.0

    /// Seconds for both strokes and the fade.
    static let duration = 4.8

    var body: some View {
        ScreenTrackpadHintFrame(progress: reduceMotion ? nil : progress)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                // motion: allow one linear timeline that the hand's pose is read from; Reduce Motion draws a still hand
                withAnimation(.linear(duration: Self.duration)) {
                    progress = 1
                } completion: {
                    finished()
                }
            }
    }
}

/// One frame of the hint at `progress` (0...1 over the whole hint; nil: the still hand).
/// Animatable, so SwiftUI draws it for every value in between.
struct ScreenTrackpadHintFrame: View, Animatable {
    var progress: Double?

    // Only the frame's own value: SwiftUI reads and writes it off the view's update.
    nonisolated var animatableData: Double {
        get { progress ?? 0 }
        set { if progress != nil { progress = newValue } }
    }

    var body: some View {
        let pose = ScreenTrackpadHintPose(progress: progress)
        GeometryReader { proxy in
            let point = CGPoint(x: pose.x * proxy.size.width, y: pose.y * proxy.size.height)
            ZStack {
                // The tap's ripple where the fingertip lands.
                Circle()
                    .stroke(Color.white.opacity(0.55 * pose.ripple), lineWidth: 2)
                    .frame(width: 46, height: 46)
                    .scaleEffect(0.5 + (1 - pose.ripple))
                    .position(point)
                Image(systemName: "hand.point.up.left.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .scaleEffect(pose.scale, anchor: .topLeading)
                    // The fingertip (the symbol's top-left) sits on the point, not the symbol's middle.
                    .position(x: point.x + 14, y: point.y + 17)
            }
            .opacity(pose.opacity)
        }
    }
}

/// Where the hint's hand is at a moment: positions as fractions of the pad,
/// the press as a scale, the tap's ripple and the fade-in and -out.
/// Each of the two strokes glides from lower left to upper right, then taps.
struct ScreenTrackpadHintPose: Equatable {
    var x = 0.5, y = 0.55, scale = 1.0, ripple = 0.0, opacity = 1.0

    /// nil: the still hand (Reduce Motion), in the middle.
    init(progress: Double?) {
        guard let progress else { return }
        let t = min(max(progress, 0), 1)
        // Fade in over the first 6 %, out over the last 10 %.
        opacity = min(1, t / 0.06, (1 - t) / 0.10)
        // Two strokes, each 45 % of the hint; the rest is the fade.
        let stroke = min(t / 0.45, 1.999)
        let local = stroke - stroke.rounded(.down)
        let from = (x: 0.28, y: 0.70), to = (x: 0.66, y: 0.36)
        let glide = Self.ease(min(local / 0.55, 1))
        x = from.x + (to.x - from.x) * glide
        y = from.y + (to.y - from.y) * glide
        // After the glide: press (to 0.86) and release, with a ripple that fades as it grows.
        let tap = max(0, (local - 0.62) / 0.3)
        if tap > 0, tap < 1 {
            scale = 1 - 0.14 * sin(.pi * min(tap * 2, 1))
            ripple = tap < 0.5 ? 0 : 1 - (tap - 0.5) * 2
        }
        if t >= 0.9 { (x, y) = to }
    }

    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
#endif
