import UIKit

/// A toolbar button that carries the configurable item it represents.
///
/// The accessory bar mixes built-in shortcuts and user-defined custom actions,
/// so the button can no longer be identified by an `Int` tag alone (custom
/// actions are keyed by `UUID`). Holding the resolved ``ResolvedToolbarItem``
/// lets tap dispatch and the armed-modifier styling/relabel loops recover the
/// exact action without a lossy tag round-trip. The structural dismiss and
/// "customize" buttons are plain `UIButton`s, so those loops naturally skip
/// them by only matching `AccessoryActionButton`.
final class AccessoryActionButton: UIButton {
    /// The configurable item this button triggers.
    let item: ResolvedToolbarItem

    /// Whether this modifier is double-tap *sticky-locked* (vs. single-tap armed).
    ///
    /// A sticky-locked modifier stays applied to every keystroke until the user
    /// taps it off, whereas an armed modifier is consumed by the next key. On
    /// iOS 26 both states share the same prominent-glass blue fill, so the lock
    /// needs its own visual cue: a white capsule border drawn on the button's
    /// layer, *over* the glass, mirroring the 2pt white stroke the pre-26 flat
    /// style already used for the locked state. The border is drawn at the layer
    /// level (not via `UIButton.Configuration.background.strokeColor`) so it
    /// composites on top of Liquid Glass regardless of how the glass material
    /// renders its own background, and adds zero intrinsic width so it does not
    /// fight the bar's min-width sizing.
    var isStickyLocked = false {
        didSet {
            guard oldValue != isStickyLocked else { return }
            updateStickyLockBorder()
        }
    }

    /// Contrasting stroke used to distinguish the sticky modifier state.
    var stickyLockBorderColor: UIColor = .white {
        didSet { updateStickyLockBorder() }
    }

    /// Width of the sticky-lock capsule border, matching the pre-26 flat stroke.
    private static let stickyLockBorderWidth: CGFloat = 2

    /// Creates a button bound to a resolved toolbar item.
    /// - Parameter item: The built-in or custom action the button represents.
    init(item: ResolvedToolbarItem) {
        self.item = item
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the lock border a true capsule that hugs the glass pill as the
        // button's bounds settle (height is fixed, but the corner radius is
        // derived here so the border tracks any future sizing change).
        updateStickyLockBorder()
    }

    /// Sync the layer-level white capsule border to ``isStickyLocked``.
    ///
    /// Always clears the border when not locked, so a button that transitions
    /// locked → armed → resting never keeps a stale border.
    private func updateStickyLockBorder() {
        if isStickyLocked {
            layer.cornerRadius = bounds.height / 2
            layer.cornerCurve = .continuous
            layer.borderColor = stickyLockBorderColor.cgColor
            layer.borderWidth = Self.stickyLockBorderWidth
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }
}
