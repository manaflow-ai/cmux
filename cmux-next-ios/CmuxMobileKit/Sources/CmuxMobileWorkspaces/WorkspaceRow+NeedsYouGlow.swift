#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import QuartzCore
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// "Needs you" as motion (Settings → Needs You Look, the Mac's `notifications.attention.mark` `glow`;
/// Leo 2026-11-19, a look customization off by default): the iPhone half of the Mac's
/// `WorkspaceRowView+NeedsYouGlow`. A workspace row that waits for the person (Needs You, or Done:
/// what its gutter dot would say) draws no dot; it breathes a soft halo in that dot's color until
/// it is opened on this phone. A row that still waits once opened shows its dot again. The dot only
/// goes transparent, so nothing in the row moves, and line 2 still says "Needs you" or "Done", so the
/// glow is never the only cue (VoiceOver reads the row as before).
extension WorkspaceRow {
    /// Whether a row glows in place of its dot: the look is Glow, the row waits for the person
    /// (needs you or done), and this phone has not opened it since its last activity (`seenAt`,
    /// `AppStore.markSeen`). Badge, the default, never glows.
    static func glows(status: WorkspaceStatus, look: AttentionMarkLook, seenAt: Date?, lastActivityAt: Date) -> Bool {
        guard look == .glow else { return false }
        let unseen = seenAt.map { $0 < lastActivityAt } ?? true
        switch status {
        case .needsYou, .done: return unseen
        case .creating, .offline, .working, .idle: return false
        }
    }

    /// The dot's color the halo takes: needs you's warning, done's label; nil for a row with no dot to stand in for.
    static func glowColor(_ status: WorkspaceStatus) -> UIColor? {
        switch status {
        case .needsYou: theme.colors.warning.uiColor
        case .done: theme.colors.label.uiColor
        case .creating, .offline, .working, .idle: nil
        }
    }

    /// The halo behind the row: inset 6 pt from the cell's edges, past the row's text vertically
    /// as the press fill is (`RowPressStyle`).
    @ViewBuilder var needsYouGlow: some View {
        if glows, let color = Self.glowColor(status) {
            NeedsYouGlow(color: color)
                .padding(.vertical, -6)
                .padding(.leading, 6)
                .padding(.trailing, -14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The halo: a 16% fill and a soft edge in the dot's color, breathing opacity 1 → 0.35 on the render
/// server (no per-frame body or main-thread work), steady at full strength under Reduce Motion.
struct NeedsYouGlow: UIViewRepresentable {
    let color: UIColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> NeedsYouGlowView { NeedsYouGlowView() }

    func updateUIView(_ view: NeedsYouGlowView, context: Context) {
        view.configure(color: color, breathes: !reduceMotion)
    }
}

final class NeedsYouGlowView: UIView {
    static let breathKey = "row.needsYouGlow"
    /// The halo's lowest opacity in a breath: it never fully goes, so a glance always finds it (the Mac's).
    static let low: Float = 0.35
    /// One breath, the Mac's `breath` period.
    static let period: CFTimeInterval = 2.4

    private var color: UIColor = .clear
    private(set) var breathes = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: NeedsYouGlowView, _: UITraitCollection) in
            view.applyColor()
        }
        // The system drops layer animations while the app is in the background.
        NotificationCenter.default.addObserver(self, selector: #selector(restartBreath),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(color: UIColor, breathes: Bool) {
        self.color = color
        applyColor()
        if breathes != self.breathes {
            self.breathes = breathes
            updateBreath()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBreath()
    }

    private func applyColor() {
        let resolved = color.resolvedColor(with: traitCollection)
        backgroundColor = resolved.withAlphaComponent(0.16)
        layer.borderColor = resolved.withAlphaComponent(0.45).cgColor
    }

    @objc private func restartBreath() {
        layer.removeAnimation(forKey: Self.breathKey)
        updateBreath()
    }

    /// Breathes while on screen and Reduce Motion is off; else holds still at full strength.
    private func updateBreath() {
        guard breathes, window != nil else {
            layer.removeAnimation(forKey: Self.breathKey)
            return
        }
        guard layer.animation(forKey: Self.breathKey) == nil else { return }
        // motion: allow the breath is the look itself; Reduce Motion never starts it (`breathes`), and a
        // row off screen drops it (`didMoveToWindow`).
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = Self.low
        breath.duration = Self.period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        // Every glowing row in step: the phase from the clock.
        breath.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        layer.add(breath, forKey: Self.breathKey)
    }
}
#endif
