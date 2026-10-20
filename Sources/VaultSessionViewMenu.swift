import AppKit
import SwiftUI

/// The row densities the Vault offers. `isCompact` maps onto the persisted
/// `sessionIndex.compactView` preference.
enum VaultSessionViewOption: CaseIterable {
    case standard
    case compact

    init(isCompact: Bool) {
        self = isCompact ? .compact : .standard
    }

    var isCompact: Bool { self == .compact }

    var label: String {
        switch self {
        case .standard:
            return String(localized: "sessionIndex.view.default", defaultValue: "Default view")
        case .compact:
            return String(localized: "sessionIndex.view.compact", defaultValue: "Compact view")
        }
    }
}

/// Presents the Vault's view-density menu as a native `NSMenu` below a
/// SwiftUI chrome button.
///
/// The button stays a plain `Button` in `RightSidebarHeaderIconButtonStyle`,
/// so it renders exactly like the right sidebar's other header controls.
/// A SwiftUI `Menu` cannot host that style or the AppKit-backed symbol
/// renderer in its label, which is what produced the hand-drawn "⋮" glyph
/// this replaces.
@MainActor
final class VaultSessionViewMenuPresenter {
    fileprivate weak var anchorView: NSView?

    static let title = String(localized: "sessionIndex.view.title", defaultValue: "Session view")

    /// Pops the menu below the anchor. Returns false when the anchor has not
    /// been laid out yet, so a press before layout is a no-op.
    @discardableResult
    func present(
        isCompactView: Bool,
        onSelect: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let anchorView else { return false }
        let menu = NSMenu(title: Self.title)
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: Self.title))
        for option in VaultSessionViewOption.allCases {
            let item = SidebarRowClosureMenuItem(title: option.label) {
                onSelect(option.isCompact)
            }
            item.state = option.isCompact == isCompactView ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.height + 2),
            in: anchorView
        )
        return true
    }
}

/// Geometry-only AppKit view placed behind the menu button. It never takes
/// clicks; it only gives the `NSMenu` a view to pop up from.
struct VaultSessionViewMenuAnchor: NSViewRepresentable {
    let presenter: VaultSessionViewMenuPresenter

    func makeNSView(context: Context) -> VaultSessionViewMenuAnchorView {
        let view = VaultSessionViewMenuAnchorView()
        presenter.anchorView = view
        return view
    }

    func updateNSView(_ nsView: VaultSessionViewMenuAnchorView, context: Context) {
        presenter.anchorView = nsView
    }
}

final class VaultSessionViewMenuAnchorView: NSView {
    /// Flipped so "just below the bottom edge" is `bounds.height + 2`, the
    /// same convention as the sidebar's other popup anchors.
    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
