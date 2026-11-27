public import Foundation

public extension ActionInvocation {
    /// An `openBrowser` run that opens `url` in the pane holding tab `tab`, behind: the tab stays
    /// unselected and no view changes, also when no window shows that workspace (the off-screen open).
    ///
    /// A link a terminal program opens from a workspace no window shows uses it, so the page lands
    /// beside its caller instead of in the workspace the person is looking at.
    ///
    /// - Parameter url: the page to open.
    /// - Parameter tab: the id or resource id of the tab whose pane gets the new tab.
    /// - Returns: a `.cli` invocation aimed at `tab` with `opensInBackground` set.
    static func opening(_ url: URL, behind tab: String) -> ActionInvocation {
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), arguments: ["url": .string(url.absoluteString)], origin: .cli)
        invocation.opensInBackground = true
        return invocation
    }
}
