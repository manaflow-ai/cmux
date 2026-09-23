#if os(iOS)
import SwiftUI
import UIKit

/// Hosts horizontally scrolling pills in a real UIKit scroll view while keeping
/// its fixed controls above the scrolling content at either edge.
struct HorizontalEdgeFadePillBar<Leading: View, Pills: View, Trailing: View>: UIViewControllerRepresentable {
    let contentInsets: UIEdgeInsets
    let accessibilityIdentifier: String
    let leading: Leading
    let pills: Pills
    let trailing: Trailing

    init(
        contentInsets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8),
        accessibilityIdentifier: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder pills: () -> Pills,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.contentInsets = contentInsets
        self.accessibilityIdentifier = accessibilityIdentifier
        self.leading = leading()
        self.pills = pills()
        self.trailing = trailing()
    }

    func makeUIViewController(context: Context) -> HorizontalEdgeFadePillBarViewController<Leading, Pills, Trailing> {
        HorizontalEdgeFadePillBarViewController(
            contentInsets: contentInsets,
            accessibilityIdentifier: accessibilityIdentifier,
            leading: leading,
            pills: pills,
            trailing: trailing
        )
    }

    func updateUIViewController(
        _ viewController: HorizontalEdgeFadePillBarViewController<Leading, Pills, Trailing>,
        context: Context
    ) {
        viewController.update(
            leading: leading,
            pills: pills,
            trailing: trailing
        )
    }
}
#endif
