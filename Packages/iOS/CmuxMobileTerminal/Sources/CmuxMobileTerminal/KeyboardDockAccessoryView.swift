#if canImport(UIKit)
import UIKit

/// The bottom dock (accessory toolbar row + composer band) as a self-sizing
/// keyboard accessory.
///
/// The system positions this view: while a text responder owns the keyboard it
/// rides the keyboard's own animation (rises, dismissals, and interactive
/// gestures included), and while the surface itself is first responder — the
/// keyboard-down state — the system docks it at the screen bottom. Ownership by
/// the keyboard window replaces the previous constraint stack (layout-guide
/// equality, notification floor, safe-area cap), whose inputs proved unreliable
/// on device: the layout guide froze or lagged transitions and the surface's
/// own frame breathes by the home-indicator height mid-transition, so any
/// self-computed position was wrong at some point of every animation.
///
/// Self-sizing: `allowsSelfSizing` with internal constraints. The content pins
/// to the safe-area bottom, so the docked state automatically clears the home
/// indicator and the keyboard-attached state sits flush on the keyboard.
final class KeyboardDockAccessoryView: UIInputView {
    private let toolbarSlot: UIView
    private let composerSlot: UIView
    private let toolbarHeight: NSLayoutConstraint
    private let composerHeight: NSLayoutConstraint
    /// Paints the accessory's region BELOW the safe-area bottom (the
    /// home-indicator inset in the docked state). The content pins to the
    /// safe-area bottom, so without this the strip under the composer band
    /// renders the bare window — a black remainder at the screen's very
    /// bottom. On the keyboard the inset is zero and the fill collapses.
    private let bottomFill = UIView()

    /// Creates the dock accessory around the surface-owned toolbar and
    /// composer container views.
    ///
    /// - Parameters:
    ///   - toolbar: The accessory toolbar row (modifiers, Tab/Esc, toggle).
    ///   - composer: The composer band container the host mounts SwiftUI into.
    ///   - toolbarRowHeight: The fixed toolbar strip height.
    init(toolbar: UIView, composer: UIView, toolbarRowHeight: CGFloat) {
        toolbarSlot = toolbar
        composerSlot = composer
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: toolbarRowHeight)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        // The dock's Liquid-Glass controls lift past the band edge on drag.
        clipsToBounds = false

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        bottomFill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomFill)
        addSubview(toolbar)
        addSubview(composer)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            composer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerHeight,
            // Safe-area pin: docked = clears the home indicator; on the
            // keyboard = flush (the keyboard region has no bottom inset).
            composer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            // Overlap the fill one point into the band so no hairline seam
            // shows between the band's background and the inset fill.
            bottomFill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -1),
            bottomFill.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomFill.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomFill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Matches the fill to the terminal theme's bar background; the surface
    /// re-applies it on theme changes.
    func setBottomFillColor(_ color: UIColor) {
        bottomFill.backgroundColor = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The dock's content height above the accessory's safe-area inset.
    var contentHeight: CGFloat {
        toolbarHeight.constant + composerHeight.constant
    }

    /// Resizes the composer band (0 collapses it while the composer is closed).
    ///
    /// - Parameter height: The band height in points.
    /// - Returns: Whether the height changed.
    @discardableResult
    func setComposerBandHeight(_ height: CGFloat) -> Bool {
        let clamped = max(0, height)
        guard abs(composerHeight.constant - clamped) > 0.25 else { return false }
        composerHeight.constant = clamped
        return true
    }
}

/// The composer band container that rides inside ``KeyboardDockAccessoryView``.
///
/// The hosted compose field is a SwiftUI `TextField`, which cannot override
/// `inputAccessoryView`. UIKit resolves input views by walking the responder
/// chain UP from the first responder, and this container is always in the
/// focused field's chain, so it supplies the shared dock on the field's
/// behalf. Without this, focusing the field resolves a nil accessory and the
/// system dismisses the dock mid-transition — the very view the field lives
/// in — killing the focus and bouncing the dock instead of raising the
/// keyboard.
final class KeyboardDockComposerContainerView: UIView {
    /// Returns the shared dock accessory (or nil while the chrome is hidden),
    /// mirroring the surface's own `inputAccessoryView` policy.
    var keyboardAccessoryProvider: (() -> UIView?)?

    override var inputAccessoryView: UIView? { keyboardAccessoryProvider?() }
}
#endif
