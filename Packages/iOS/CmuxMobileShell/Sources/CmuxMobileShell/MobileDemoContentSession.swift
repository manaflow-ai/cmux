import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

/// The live state behind demonstration content while the signed-in account is
/// server-flagged for it: the canned catalog, the interactive terminal engine,
/// and the bookkeeping the shell needs to seed and tear down cleanly.
///
/// The session only holds data; every visible effect flows through the
/// shell's ordinary stores (`workspacesByMac`, the notification-feed
/// snapshots, the paired-Mac list) so the demonstration computer renders
/// through exactly the same derivations and views as a live Mac.
@MainActor
final class MobileDemoContentSession {
    /// The canned computer, workspaces, notifications, and terminal scripts.
    let catalog: MobileDemoContentCatalog
    /// The local PTY simulacrum answering demo terminal input.
    let engine: MobileDemoTerminalEngine
    /// This Mac's workspaces, mutable so read receipts (unread clearing)
    /// behave like a real Mac's while the session lives.
    private(set) var workspaces: [MobileWorkspacePreview]
    /// Monotonic feed revision for in-memory read-state mutations, mirroring
    /// the revision contract a live Mac's feed follows.
    private(set) var notificationFeedRevision = 1
    /// Whether activation forced the persisted known-paired-Mac hint on, so
    /// deactivation restores it when no real Macs are stored.
    var forcedKnownPairedMacHint = false

    /// The demo pairing's key in the per-Mac workspace map.
    let pairingKey = MacPairingKey(
        macDeviceID: MobileDemoContentCatalog.macDeviceID,
        instanceTag: nil
    )

    /// The demo pairing's owner key in the feed snapshot dictionaries.
    var feedOwnerKey: String { pairingKey.pairingID }

    init(now: Date) {
        let catalog = MobileDemoContentCatalog.standard(now: now)
        self.catalog = catalog
        self.engine = MobileDemoTerminalEngine(scripts: catalog.terminalScripts)
        self.workspaces = catalog.workspaces
    }

    /// The per-Mac workspace state to seed into the shell's source of truth.
    /// Connected, with no mutation capabilities: rows render and open like a
    /// live Mac's, while rename/close/move affordances stay hidden.
    var workspaceState: MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: MobileDemoContentCatalog.macDeviceID,
            instanceTag: nil,
            displayName: MobileDemoContentCatalog.displayName,
            workspaces: workspaces,
            groups: [],
            workspaceGroupsAreAuthoritative: true,
            status: .connected,
            actionCapabilities: .none
        )
    }

    /// Whether the given Mac identity is the demonstration computer.
    func ownsMac(deviceID: String?, instanceTag: String?) -> Bool {
        guard let deviceID, !deviceID.isEmpty else { return false }
        return MacPairingKey(macDeviceID: deviceID, instanceTag: instanceTag) == pairingKey
    }

    /// Whether the given terminal surface belongs to a demo workspace.
    func ownsSurface(_ surfaceID: String) -> Bool {
        engine.ownsSurface(surfaceID)
    }

    /// Marks one demo workspace read, mirroring the read receipt a live Mac
    /// applies when a workspace is opened. Returns whether anything changed.
    @discardableResult
    func clearWorkspaceUnread(remoteWorkspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.rpcWorkspaceID == remoteWorkspaceID }),
              workspaces[index].hasUnread else {
            return false
        }
        workspaces[index].hasUnread = false
        workspaces[index].unreadCount = nil
        return true
    }

    /// Bumps and returns the next feed revision for an in-memory mutation.
    func nextNotificationFeedRevision() -> Int {
        notificationFeedRevision += 1
        return notificationFeedRevision
    }
}
