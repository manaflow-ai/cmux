#if os(iOS)
import Observation
import SwiftUI
import UIKit

enum JoystickDirection: Sendable, Equatable {
    case up, down, left, right

    var key: KeyBarKey {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

/// The joystick's state machine (SPEC 10.3, Codex QA F5): direction is
/// quantized to 4 ways; the first key fires on crossing the 8 pt dead zone,
/// and a hold repeats like a held key (`JoystickRepeat`). A haptic per key.
@MainActor
@Observable
final class JoystickEngine {
    static let radius: CGFloat = 28
    static let deadZone: CGFloat = JoystickRepeat.deadZone
    /// The thumb's lowest point: inside the key row and the composer below
    /// it, above the keyboard.
    static let maxDownwardThumb: CGFloat = 14

    private(set) var thumb: CGSize = .zero
    private(set) var gear = 0
    private(set) var direction: JoystickDirection?
    private(set) var keysSent = 0
    /// The finger's distance from the center now (the repeat rate follows it).
    private var distance: CGFloat = 0
    var send: (JoystickDirection) -> Void = { _ in }

    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .light)

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    static func gear(for distance: CGFloat) -> Int {
        switch distance {
        case ..<deadZone: 0
        case ..<16: 1
        case ..<24: 2
        default: 3
        }
    }

    static func interval(gear: Int) -> Duration {
        switch gear {
        case 1: .milliseconds(160)
        case 2: .milliseconds(80)
        default: .milliseconds(30)
        }
    }

    static func direction(for offset: CGSize) -> JoystickDirection {
        abs(offset.width) >= abs(offset.height)
            ? (offset.width >= 0 ? .right : .left)
            : (offset.height >= 0 ? .down : .up)
    }

    /// The finger moved to `translation` from the center.
    func update(_ translation: CGSize) {
        let distance = hypot(translation.width, translation.height)
        self.distance = distance
        // The thumb follows the finger past the circle, so the finger does
        // not cover it (user note 2026-10-14); the floating copy draws it,
        // never lower than the key bar's bottom: the keyboard window is above
        // the page and would hide it (Codex QA F6).
        var offset = JoystickGeometry().thumbOffset(for: translation)
        offset.height = min(offset.height, Self.maxDownwardThumb)
        thumb = offset
        let newGear = Self.gear(for: distance)
        let newDirection = newGear == 0 ? nil : Self.direction(for: translation)
        let crossed = gear == 0 && newGear > 0
        let changedDirection = newDirection != direction
        gear = newGear
        direction = newDirection
        guard let newDirection else {
            repeatTask?.cancel()
            repeatTask = nil
            return
        }
        if crossed || changedDirection {
            fire(newDirection)
            restartRepeat()
        }
    }

    func release() {
        repeatTask?.cancel()
        repeatTask = nil
        gear = 0
        direction = nil
        thumb = .zero
        touching = false
        // The floating thumb springs back before the circle's own takes over
        // (a bounded animation length, not synchronization).
        returning = true
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: .milliseconds(350))
            if !Task.isCancelled { self?.returning = false }
        }
    }

    /// The finger is on the joystick.
    var touching = false {
        didSet { if touching { returnTask?.cancel(); returning = false } }
    }
    /// Springing back after release.
    private(set) var returning = false
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    /// The circle's center in global coordinates (for the floating thumb).
    var center: CGPoint = .zero
    /// The thumb is drawn above the key bar, unclipped, while dragged.
    var showsFloatingThumb: Bool { touching || returning }

    private func fire(_ direction: JoystickDirection) {
        keysSent += 1
        send(direction)
        impact.impactOccurred(intensity: 0.6)
    }

    /// One arrow already went; held, it repeats after 400 ms at the rate
    /// the distance gives (`JoystickRepeat`, iOS key repeat).
    private func restartRepeat() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: JoystickRepeat.initialDelay) } catch { return }
            while let self, !Task.isCancelled, let direction = self.direction {
                self.fire(direction)
                do { try await self.clock.sleep(for: JoystickRepeat().interval(distance: self.distance)) } catch { return }
            }
        }
    }
}

/// The joystick's thumb while dragged, drawn over the whole terminal page so
/// the key bar's clip does not cut it: it follows the finger up to 1.5x the
/// circle and springs back on release (user note 2026-10-14).
struct JoystickThumbOverlay: View {
    let engine: JoystickEngine

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if engine.showsFloatingThumb {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 12, height: 12)
                    .scaleEffect(engine.touching ? 1.2 : 1)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(x: engine.center.x - origin.x + engine.thumb.width,
                              y: engine.center.y - origin.y + engine.thumb.height)
                    .animation(engine.touching ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: engine.thumb)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct Joystick: View {
    let engine: JoystickEngine

    var body: some View {
        // Classic cmux iOS's arrow nub: a 28 pt circle with a 12 pt dot.
        let size = JoystickGeometry.circle
        Circle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 12, height: 12)
            // While dragged the dot is drawn above the key row, where it can
            // leave the circle (`JoystickThumbOverlay`).
            .opacity(engine.showsFloatingThumb ? 0 : 1)
            .frame(width: size, height: size)
            // A glass circle under the dot, as classic's nub (`UIGlassEffect`);
            // not interactive: the drag owns the touch. The dot draws on top,
            // crisp.
            .glassEffect(engine.gear > 0 ? .regular.tint(Color.white.opacity(0.15)) : .regular, in: .circle)
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { engine.center = $0 }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !engine.touching { engine.touching = true }
                    engine.update(value.translation)
                }
                .onEnded { _ in
                    engine.release()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Cursor joystick")
        .accessibilityHint("Drag to move the cursor; farther moves faster.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: engine.send(.right)
            case .decrement: engine.send(.left)
            @unknown default: break
            }
        }
    }
}
#endif
