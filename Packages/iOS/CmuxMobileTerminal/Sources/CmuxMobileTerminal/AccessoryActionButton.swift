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
    /// taps it off, whereas an armed modifier is consumed by the next key. The
    /// property is retained for the toolbar state machine; the current flat
    /// configuration draws its locked stroke directly.
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

    /// Width of the legacy sticky-lock border.
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
        // Keep the legacy lock border aligned as the button's bounds settle.
        updateStickyLockBorder()
    }

    /// Sync the legacy layer border to ``isStickyLocked``.
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
