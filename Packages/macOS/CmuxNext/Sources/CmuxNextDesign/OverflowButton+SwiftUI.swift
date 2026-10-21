public import AppKit
public import SwiftUI

/// ``OverflowButton`` in a SwiftUI page (the bookmark manager's ⋮): the same glyph, hit target and
/// hover as the sidebar's and the pane toolbar's, and its menu opens on press. The page's host
/// builds the menu (the action registry's rows), so a SwiftUI page never draws its own rows.
public struct OverflowMenuButton: NSViewRepresentable {
    /// The square the button takes: the sidebar controls' hit target.
    public static var side: CGFloat { Metrics.iconSize + Metrics.space2 }

    private let label: String
    private let identifier: String?
    private let menu: @MainActor () -> NSMenu?

    public init(label: String, identifier: String? = nil, menu: @escaping @MainActor () -> NSMenu?) {
        self.label = label
        self.identifier = identifier
        self.menu = menu
    }

    public func makeNSView(context: Context) -> OverflowButton {
        OverflowButton(label: label)
    }

    public func updateNSView(_ button: OverflowButton, context: Context) {
        let menu = menu
        button.pressMenu = { menu() }
        button.label = label
        button.setAccessibilityIdentifier(identifier)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverflowButton, context: Context) -> CGSize? {
        CGSize(width: Self.side, height: Self.side)
    }
}
