#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// A workspace open over the list takes the list off screen; a busy Mac's
/// pushes must not diff and lay it out on main while the person types in the
/// workspace's composer. The list applies the latest model when it comes back.
@MainActor
@Suite struct WorkspacesOffscreenApplyTests {
    private func model(_ title: String) -> WorkspacesListModel {
        WorkspacesListModel(sections: [ListSectionIDs(id: "s", items: ["t.\(title)"])], items: ["t.\(title)": .title(title)])
    }

    /// Yields to the main run loop until `done`, for at most `seconds`.
    private func frames(for seconds: Double = 3, until done: () -> Bool) async {
        let deadline = CACurrentMediaTime() + seconds
        while !done(), CACurrentMediaTime() < deadline { await Task.yield() }
    }

    @Test func aHiddenListHoldsPushesAndAppliesTheLatestWhenShown() async {
        let list = WorkspacesListController(control: WorkspacesListControl())
        let view = list.makeView()
        let screen = UIViewController()
        view.frame = screen.view.bounds
        screen.view.addSubview(view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        let actions = WorkspacesCollectionActions(
            row: { _ in preconditionFailure("no rows") },
            content: { _, _ in AnyView(EmptyView()) },
            menu: { _, _ in nil },
            swipe: { _, _ in nil },
            refresh: nil
        )
        list.update(model: model("a"), actions: actions, animated: false, membershipKey: 0)
        await frames { list.applyCount == 1 }
        #expect(list.applyCount == 1)

        view.removeFromSuperview()
        for name in ["b", "c", "d"] {
            list.update(model: model(name), actions: actions, animated: false, membershipKey: 0)
            await frames(for: 0.2) { list.applyCount > 1 }
        }
        #expect(list.applyCount == 1, "the hidden list applied a push")

        screen.view.addSubview(view)
        #expect(list.applyCount == 2, "the list came back without the latest push")
        window.isHidden = true
    }
}
#endif
