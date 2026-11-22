import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSidebar
import Observation

/// When a window's sidebar holds its drawn order (`SidebarModel.holdsLaunchOrder`, the Rust rule
/// `sidebar_launch_order`, Leo 2026-11-09: "tens of seconds after restarting to update the sidebar kinda reshuffled or
/// something weird"): until the home session's owner serves. It serves once the home daemon is connected, this
/// connection's live tree has replaced the launch snapshot's (`liveTreeEpoch`, so a reconnect in place holds too; the
/// connection object alone stays set while it reconnects, #39219), and the sidebar document is the daemon's, not the
/// launch snapshot's.
@MainActor public struct SidebarLaunchOrderHold {
    private let home: DaemonStore
    private let document: @MainActor () -> SidebarDocStore?

    /// `home`: the home session's daemon store; `document`: the app's sidebar document store (nil before it starts).
    public init(home: DaemonStore, document: @escaping @MainActor () -> SidebarDocStore?) {
        self.home = home
        self.document = document
    }

    /// Whether the home session's owner serves the sidebar.
    public var ownerServes: Bool {
        guard case .connected = home.connectionState, home.isLoaded, !home.isProvisional,
              home.liveTreeEpoch == home.connectionEpoch else { return false }
        return document()?.isProvisional != true
    }

    /// Holds `model`'s drawn order now and whenever the owner does not serve, until the task is cancelled.
    public func follow(_ model: SidebarModel) -> Task<Void, Never> {
        model.holdsLaunchOrder = !ownerServes
        let hold = self
        // task-owner: the window's sidebar (cancelled with its sections observation at teardown); event-driven (Observation)
        return Task { [weak model] in
            for await serves in ObservationStream({ hold.ownerServes }) {
                guard let model else { return }
                model.holdsLaunchOrder = !serves
            }
        }
    }
}
