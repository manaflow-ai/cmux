import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileShellModel
import Foundation

/// Demonstration content: a local demo computer with sample workspaces,
/// notifications, and interactive canned terminals, activated only while the
/// signed-in account carries the server-written demonstration flag
/// (`CMUXAuthUser.demonstrationContentEnabled`).
///
/// Everything renders through the production data paths: the demo computer is
/// one more `MobilePairedMac` row (via ``DemoContentPairedMacStore``), its
/// workspaces are one more ``MacWorkspaceState`` entry feeding the ordinary
/// multi-Mac aggregation, its notifications are one more per-Mac feed
/// snapshot, and its terminals are served by ``MobileDemoTerminalEngine``
/// through the same output stream and input funnels a live Mac uses. Real
/// Macs connect, list, and stream exactly as before — demonstration content
/// augments the account's data, it never replaces or intercepts a real Mac's.
///
/// Ownership is derived from the stable `cmux-demo-` identifier namespace
/// (``MobileDemoContentCatalog/ownsIdentifier(_:)``), never from live session
/// state, so every connection-lifecycle fence holds through any app
/// lifecycle. The session itself SELF-HEALS at interaction time: if a demo
/// surface is interacted with (mount, replay, input) after the session was
/// torn down underneath a still-presented view, the interaction recreates the
/// session and reseeds, so a demo workspace opened any number of times, after
/// any background/foreground churn, always paints and always answers input.
@MainActor
extension MobileShellComposite {
    /// The demonstration pairing's stable key, independent of session state.
    static let demonstrationPairingKey = MacPairingKey(
        macDeviceID: MobileDemoContentCatalog.macDeviceID,
        instanceTag: nil
    )

    // MARK: Activation

    /// Re-evaluates demonstration-content activation against the signed-in
    /// account's server flag. Called on every shell auth sync AND at the top
    /// of every paired-Mac list load: the flag can arrive through session
    /// revalidation after the last auth sync (a cached identity card
    /// predating the flag decodes as not-flagged), and the store decorator
    /// reads it lazily, so any load that can reveal the demo row must seed
    /// with it.
    /// - Parameter reloadPairedMacs: Whether an activation edge should also
    ///   re-run the paired-Mac list load. `false` when the caller IS that
    ///   load, which will pick the row up itself in the same pass.
    func refreshDemonstrationContentActivation(reloadPairedMacs: Bool = true) {
        let enabled = isSignedIn
            && identityProvider?.demonstrationContentEnabled == true
        if enabled {
            activateDemonstrationContent(reloadPairedMacs: reloadPairedMacs)
        } else {
            deactivateDemonstrationContent(
                reloadPairedMacs: reloadPairedMacs && isSignedIn
            )
        }
    }

    private func activateDemonstrationContent(reloadPairedMacs: Bool) {
        if demoContentSession == nil {
            createDemonstrationSession(reloadPairedMacs: reloadPairedMacs)
        }
        seedDemonstrationState()
    }

    /// Creates the live session and arranges for the demo row to appear.
    private func createDemonstrationSession(reloadPairedMacs: Bool) {
        let session = MobileDemoContentSession(now: runtime?.now() ?? Date())
        demoContentSession = session
        // The demo computer is a known paired Mac while the session
        // lives; without the hint a reviewer with zero real Macs would
        // land on the add-device flow instead of the workspace shell.
        if !hasKnownPairedMac {
            session.forcedKnownPairedMacHint = true
            hasKnownPairedMac = true
        }
        // Reveal the demo row through the ordinary store load path.
        if reloadPairedMacs {
            Task { await self.loadPairedMacs() }
        }
    }

    /// The live session for a demonstration interaction, self-healing when a
    /// teardown removed it underneath a still-presented demo surface. The
    /// heal is gated on the shell being signed in — an account boundary
    /// (sign-out) tears everything down and must stay down.
    func demonstrationSessionForInteraction() -> MobileDemoContentSession? {
        if let session = demoContentSession { return session }
        guard isSignedIn else { return nil }
        MobileDebugLog.anchormux("demo.session_selfheal")
        createDemonstrationSession(reloadPairedMacs: true)
        seedDemonstrationState()
        return demoContentSession
    }

    /// Removes every demonstration seed. Safe to call repeatedly.
    /// - Parameter reloadPairedMacs: Whether to re-run the store load so the
    ///   Computers list drops the demo row (skipped during sign-out, whose
    ///   own teardown clears the list).
    func deactivateDemonstrationContent(reloadPairedMacs: Bool = false) {
        guard let session = demoContentSession else { return }
        demoContentSession = nil
        workspacesByMac.removeValue(forKey: session.pairingKey)
        notificationFeedSnapshotsByMac.removeValue(forKey: session.feedOwnerKey)
        notificationFeedKnownRevisionsByMac.removeValue(forKey: session.feedOwnerKey)
        notificationFeedSuccessfulMacIDs.remove(session.feedOwnerKey)
        recomputeNotificationFeedItems()
        // With no real (non-demo) rows left, the forced known-Mac hint is
        // restored so the add-device flow returns.
        if session.forcedKnownPairedMacHint,
           !pairedMacs.contains(where: { !isDemonstrationPairedMac($0) }) {
            hasKnownPairedMac = false
        }
        if reloadPairedMacs {
            Task { await self.loadPairedMacs() }
        }
    }

    /// Seeds (or re-seeds) the demo Mac's workspace state and notification
    /// snapshot through the same internal stores a live Mac's data lands in.
    private func seedDemonstrationState() {
        guard let session = demoContentSession else { return }
        let state = session.workspaceState
        if workspacesByMac[session.pairingKey] != state {
            workspacesByMac[session.pairingKey] = state
        }
        if notificationFeedSnapshotsByMac[session.feedOwnerKey] == nil {
            notificationFeedSnapshotsByMac[session.feedOwnerKey] = NotificationFeedMacSnapshot(
                revision: session.notificationFeedRevision,
                items: session.catalog.notifications
            )
            notificationFeedKnownRevisionsByMac[session.feedOwnerKey] =
                session.notificationFeedRevision
            notificationFeedSuccessfulMacIDs.insert(session.feedOwnerKey)
            recomputeNotificationFeedItems()
        }
        if notificationFeedStatus == .idle || notificationFeedStatus == .unavailable {
            notificationFeedStatus = .ready
        }
    }

    // MARK: Ownership (session-independent, by identifier namespace)

    /// Whether the given Mac identity is the demonstration computer.
    /// Namespace-based, so lifecycle fences hold even while the session is
    /// torn down.
    func demonstrationOwnsMac(deviceID: String?, instanceTag: String?) -> Bool {
        guard let deviceID, !deviceID.isEmpty else { return false }
        return MacPairingKey(macDeviceID: deviceID, instanceTag: instanceTag)
            == Self.demonstrationPairingKey
    }

    /// Whether a stored paired-Mac row is the demonstration computer's.
    func isDemonstrationPairedMac(_ mac: MobilePairedMac) -> Bool {
        demonstrationOwnsMac(deviceID: mac.macDeviceID, instanceTag: mac.instanceTag)
    }

    /// Whether a terminal surface belongs to the demonstration namespace.
    func demonstrationOwnsSurface(_ surfaceID: String) -> Bool {
        MobileDemoContentCatalog.ownsIdentifier(surfaceID)
    }

    /// Whether an aggregated workspace row belongs to the demonstration Mac.
    func demonstrationOwnsWorkspaceRow(_ id: MobileWorkspacePreview.ID) -> Bool {
        guard let row = workspaces.first(where: { $0.id == id }) else { return false }
        return demonstrationOwnsMac(
            deviceID: row.macDeviceID,
            instanceTag: row.macInstanceTag
        )
    }

    // MARK: Terminal output and input

    /// Delivers the demo terminal's authoritative full-screen replay through
    /// the same per-surface output stream a live Mac's replay rides.
    ///
    /// The replay is prefixed with a screen + scrollback erase so re-delivery
    /// (view resets, viewport churn, remounts onto a live surface) repaints
    /// from blank instead of appending a second copy of the transcript.
    func deliverDemonstrationTerminalReplay(surfaceID: String) {
        guard demonstrationOwnsSurface(surfaceID),
              let session = demonstrationSessionForInteraction(),
              let bytes = session.engine.replayBytes(surfaceID: surfaceID) else { return }
        var reset = Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
        reset.append(bytes)
        _ = deliverTerminalBytes(reset, surfaceID: surfaceID)
    }

    /// Feeds typed input into the demo terminal engine and echoes its output.
    /// Returns `false` for surfaces outside the demonstration namespace, so
    /// callers fall through to the real RPC input pipeline. Demo-namespace
    /// input is ALWAYS handled (never forwarded to a real Mac), even when the
    /// session cannot self-heal (signed out): no real Mac owns these ids.
    @discardableResult
    func handleDemonstrationTerminalInput(_ text: String, surfaceID: String) -> Bool {
        guard demonstrationOwnsSurface(surfaceID) else { return false }
        guard let session = demonstrationSessionForInteraction() else { return true }
        if let bytes = session.engine.inputBytes(text, surfaceID: surfaceID),
           !bytes.isEmpty {
            _ = deliverTerminalBytes(bytes, surfaceID: surfaceID)
        }
        return true
    }

    // MARK: Read receipts

    /// Applies the open-a-workspace read receipt to a demo row, mirroring the
    /// unread clearing a live Mac performs on `workspace.read_state`.
    func clearDemonstrationWorkspaceUnread(_ id: MobileWorkspacePreview.ID) {
        guard let session = demonstrationSessionForInteraction() else { return }
        let remoteID = remoteWorkspaceID(for: id)
        guard session.clearWorkspaceUnread(remoteWorkspaceID: remoteID) else { return }
        workspacesByMac[session.pairingKey] = session.workspaceState
    }

    /// Applies a feed read-state mutation to a demo notification in memory.
    /// Returns `false` when the item is not demonstration-owned.
    func applyDemonstrationNotificationReadState(
        _ item: MobileNotificationFeedItem,
        isRead: Bool
    ) -> Bool {
        guard demonstrationOwnsMac(
            deviceID: item.macDeviceID,
            instanceTag: item.macInstanceTag
        ), let session = demoContentSession else {
            return false
        }
        guard item.isRead != isRead else { return true }
        applyNotificationFeedReadStateMutation(
            macDeviceID: session.feedOwnerKey,
            notificationIDs: [item.notificationID],
            isRead: isRead,
            revision: session.nextNotificationFeedRevision()
        )
        return true
    }

    /// Marks the demo Mac's retained notifications read for a bulk mark-read,
    /// honoring the caller's computer scope like the real per-Mac targets.
    func markDemonstrationNotificationFeedItemsRead(scopedTo macDeviceIDs: Set<String>?) {
        guard let session = demoContentSession,
              let snapshot = notificationFeedSnapshotsByMac[session.feedOwnerKey] else { return }
        if let macDeviceIDs {
            let parsedScopeEntries = MobileWorkspaceListFilter.parsedMachineEntries(macDeviceIDs)
            guard parsedScopeEntries.contains(where: {
                $0.matches(
                    deviceID: session.pairingKey.canonicalMacDeviceID,
                    rowTag: nil
                )
            }) else { return }
        }
        let unreadIDs = snapshot.items.filter { !$0.isRead }.map(\.notificationID)
        guard !unreadIDs.isEmpty else { return }
        applyNotificationFeedReadStateMutation(
            macDeviceID: session.feedOwnerKey,
            notificationIDs: unreadIDs,
            isRead: true,
            revision: session.nextNotificationFeedRevision()
        )
    }

    /// Whether the demo notification snapshot is currently seeded, so the
    /// feed's availability resolution can report `.ready` when demonstration
    /// content is the only source.
    var demonstrationNotificationFeedSeeded: Bool {
        guard let session = demoContentSession else { return false }
        return notificationFeedSnapshotsByMac[session.feedOwnerKey] != nil
    }

    // MARK: Task composer exclusion

    /// The task composer's target machines: every paired Mac EXCEPT the
    /// demonstration computer. A fake Mac cannot run real tasks, while real
    /// Macs on the same account (even offline ones) stay composable.
    public var taskComposerPairedMacs: [MobilePairedMac] {
        displayPairedMacs.filter { !isDemonstrationPairedMac($0) }
    }

    /// Whether the paired-Mac list currently holds ONLY the demonstration
    /// computer, so composer availability can drop its offline benefit of
    /// the doubt (there is provably nothing that could run a task).
    var pairedMacsAreDemonstrationOnly: Bool {
        !pairedMacs.isEmpty && pairedMacs.allSatisfy { isDemonstrationPairedMac($0) }
    }
}
