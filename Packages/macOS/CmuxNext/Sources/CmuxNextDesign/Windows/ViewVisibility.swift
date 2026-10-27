public import AppKit
public import CmuxNextWakeups
import class CmuxSafeConcurrency.Invariant

/// A view's place in the visibility tree (plans/cmux-next/chrome-parity/p06-scheduler.md, section B,
/// recipe R-hide), for a view whose `VisibleObservation`s should read only while it is on screen.
///
/// Its ``node`` sits under its window's node (``WindowVisibilitySource``), or under a hidden root while
/// the view is in no window, and its own state is AppKit's hidden state for the view. The view
/// forwards three overrides: `viewDidMoveToWindow` calls ``place(in:)``, and `viewDidHide` /
/// `viewDidUnhide` set the node hidden / visible (AppKit sends both for a hidden ancestor too). So a
/// hidden app, a miniaturized or occluded window, a parked workspace, an unselected tab and a hidden
/// ancestor all reach the view's observations as one flip, and nothing walks ancestors.
/// ``StatusIndicatorView`` places its node the same way; Chromium keeps one visibility per
/// WebContents, set by its owner (`content/public/browser/visibility.h`).
///
/// ```swift
/// let visibility = ViewVisibility("home:\(id)")
/// var visibilityNode: VisibilityNode { visibility.node }
/// override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); visibility.place(in: window) }
/// override func viewDidHide() { super.viewDidHide(); visibilityNode.set(.hidden) }
/// override func viewDidUnhide() { super.viewDidUnhide(); visibilityNode.set(.visible) }
/// ```
@MainActor public final class ViewVisibility {
    /// The view's node.
    public let node: VisibilityNode
    /// The parent of ``node`` while the view is in no window: always hidden.
    private let offWindow: VisibilityNode

    /// - Parameter name: The node's name in diagnostics (`home:<conversation>`).
    public init(_ name: String) {
        let offWindow = VisibilityNode(root: "\(name).offWindow", own: .hidden)
        self.offWindow = offWindow
        node = VisibilityNode(name, own: .visible, parent: offWindow)
    }

    /// Laid out in a shown place: on screen or in an occluded window, not hidden. An action a person
    /// aims at the front window (Stop, a settings toggle) acts on a view that another app covers.
    public var isShown: Bool { node.effective > .hidden }

    /// Puts ``node`` under `window`'s node, or under the hidden root for no window.
    ///
    /// - Parameter window: The view's window, from `viewDidMoveToWindow`.
    public func place(in window: NSWindow?) {
        let parent = window.map { WindowVisibilitySource.of($0).node } ?? offWindow
        do {
            try node.attach(to: parent)
        } catch {
            Invariant.debugCheck(false, "view-visibility-node-placed",
                                 "ViewVisibility: \(parent.name) cannot hold \(node.name) (\(error))")
        }
    }
}
