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
}
