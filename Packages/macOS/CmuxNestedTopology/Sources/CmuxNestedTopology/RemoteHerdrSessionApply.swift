public import Foundation

/// One session-level host verb. Order in a list is load-bearing.
public struct RemoteHerdrSessionAction: Hashable, Sendable {
    /// Verb name (`create_tab`, `close_tab`, `reorder_tabs`, …).
    public var op: String
    /// Target Herdr tab id when the verb is tab-scoped.
    public var tabID: String?
    /// Display title for create/rename.
    public var title: String?
    /// Desired strip order for ``reorder_tabs``.
    public var orderedTabIDs: [String]

    /// Creates a session verb.
    public init(
        op: String,
        tabID: String? = nil,
        title: String? = nil,
        orderedTabIDs: [String] = []
    ) {
        self.op = op
        self.tabID = tabID
        self.title = title
        self.orderedTabIDs = orderedTabIDs
    }
}

/// Linearizes one session reconcile into host verbs.
///
/// Order copies ``RemoteTmuxSessionMirror.rebuildTopology``: create/refresh
/// live windows first, close leftovers, drop the workspace default tab,
/// then reorder the strip to Herdr tab numbers.
public enum RemoteHerdrSessionApply {

    /// Last title wins when the provider repeats a `tabID`.
    ///
    /// - Parameter windows: Provider windows, possibly with duplicate tab ids.
    /// - Returns: `tabID` → title. Never traps on duplicates.
    public static func titlesByTabID(_ windows: [RemoteHerdrWindow]) -> [String: String] {
        var titles: [String: String] = [:]
        for window in windows {
            titles[window.tabID] = window.title
        }
        return titles
    }

    /// Builds the ordered verb list for one ``RemoteHerdrSessionReconcile``.
    public static func actions(
        _ session: RemoteHerdrSessionReconcile,
        titles: [String: String] = [:],
        previousTitles: [String: String] = [:],
        defaultsOpen: Bool = false,
        focusTabID: String? = nil
    ) -> [RemoteHerdrSessionAction] {
        var actions: [RemoteHerdrSessionAction] = []
        for tabID in session.createdTabIDs {
            actions.append(
                RemoteHerdrSessionAction(
                    op: "create_tab",
                    tabID: tabID,
                    title: titles[tabID] ?? tabID
                )
            )
        }
        for tabID in session.keptTabIDs {
            if let newTitle = titles[tabID], newTitle != previousTitles[tabID] {
                actions.append(
                    RemoteHerdrSessionAction(op: "rename_tab", tabID: tabID, title: newTitle)
                )
            }
        }
        for tabID in session.closedTabIDs {
            actions.append(RemoteHerdrSessionAction(op: "close_tab", tabID: tabID))
        }
        if defaultsOpen, !session.orderedTabIDs.isEmpty {
            actions.append(RemoteHerdrSessionAction(op: "close_default_tabs"))
        }
        if session.orderChanged, session.orderedTabIDs.count > 1 {
            actions.append(
                RemoteHerdrSessionAction(
                    op: "reorder_tabs",
                    orderedTabIDs: session.orderedTabIDs
                )
            )
        }
        if let focusTabID, session.orderedTabIDs.contains(focusTabID) {
            actions.append(RemoteHerdrSessionAction(op: "focus_tab", tabID: focusTabID))
        }
        return actions
    }
}
