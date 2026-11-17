public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextLayout

/// The size values a resize gesture ends with, in the daemon's form, for the app's intent handler. Its own type: the
/// daemon service's type is over its size budget.
public enum GestureSizeValues {
    /// The daemon's form of `values` (`LayoutHandleMap.sizeValues`); nil when one of them cannot go to the daemon now,
    /// so that none of them goes and the caller shows the daemon's sizes again.
    ///
    /// When a width's pane is still opening (a pending split's stand-in), `daemon` shows the pane-still-opening notice,
    /// in this turn: the connection would refuse a command that names a stand-in with the same notice
    /// (``PaneNotReady``), and a size that goes back with no word looks like a lost press. A value with no handle at
    /// all (its pane or split went away) says nothing: no pane is opening.
    public static func wire(_ values: [LayoutIntent.SizeValue], in handles: LayoutHandleMap,
                            noticeOn daemon: DaemonService) -> [SetLayoutSizesRequest.Value]? {
        if let wire = handles.sizeValues(values) { return wire }
        for case let .width(_, anyPane, _) in values {
            guard let handle = handles.panes[anyPane], ProvisionalPane.isStandIn(handle) else { continue }
            let command = values.count == 1 ? SetColumnWidthRequest.command : SetLayoutSizesRequest.command
            daemon.showPaneNotReady(PaneNotReady(command: command, reference: "pane=\(handle.rawValue)"))
            break
        }
        return nil
    }
}
