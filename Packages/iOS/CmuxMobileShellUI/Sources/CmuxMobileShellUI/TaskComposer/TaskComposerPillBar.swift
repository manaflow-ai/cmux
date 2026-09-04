#if os(iOS)
import SwiftUI

/// Hosts the task composer's pills in a real UIKit scroll view while keeping
/// its fixed controls above the scrolling content at either edge.
struct TaskComposerPillBar<Leading: View, Pills: View, Trailing: View>: UIViewControllerRepresentable {
    let leading: Leading
    let pills: Pills
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder pills: () -> Pills,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.pills = pills()
        self.trailing = trailing()
    }

    func makeUIViewController(context: Context) -> TaskComposerPillBarViewController<Leading, Pills, Trailing> {
        TaskComposerPillBarViewController(
            leading: leading,
            pills: pills,
            trailing: trailing
        )
    }

    func updateUIViewController(
        _ viewController: TaskComposerPillBarViewController<Leading, Pills, Trailing>,
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
