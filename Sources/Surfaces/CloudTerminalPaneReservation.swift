import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation

/// Input typed into an optimistic Cloud pane before its remote PTY exists.
///
/// The pane is inserted the moment the user asks for it; the machine's terminal
/// arrives later. Keystrokes made in between are queued here and handed to the
/// attachment's input router once the pane is adopted, so the first characters
/// a user types into a new pane are not lost.
final class CloudOptimisticInputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var router: (@Sendable (TerminalManualInput) -> Void)?
    private var pending: [TerminalManualInput] = []
    private var discarded = false
    /// Bounded like the router's own queue: a runaway paste into a pane that
    /// never attaches must not grow without limit.
    private let pendingLimit = 4_096

    /// Number of inputs waiting for a router. Diagnostics and tests only.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Callable from Ghostty's I/O thread, like the router it fronts.
    func send(_ input: TerminalManualInput) {
        lock.lock()
        if let router {
            lock.unlock()
            router(input)
            return
        }
        if !discarded, pending.count < pendingLimit { pending.append(input) }
        lock.unlock()
    }

    /// Delivers everything queued so far to `router` and forwards from now on.
    func attach(_ router: CloudTuiManualIOInputRouter) {
        attach { router.send($0) }
    }

    /// Device mirrors adopt the same pane with their own byte router.
    func attach(_ router: DeviceTerminalInputRouter) {
        attach { router.enqueue($0) }
    }

    private func attach(_ router: @escaping @Sendable (TerminalManualInput) -> Void) {
        lock.lock()
        // Enqueue the backlog before publishing the router. Both routers only
        // queue work, so holding this lock performs no socket I/O. A concurrent
        // key cannot overtake earlier input at the handoff boundary.
        for input in pending { router(input) }
        pending.removeAll()
        discarded = false
        self.router = router
        lock.unlock()
    }

    /// Drops queued input and stops forwarding: the request was cancelled or the
    /// pane failed. A later `attach` (retry) resumes forwarding.
    func discard() {
        lock.lock()
        pending.removeAll()
        router = nil
        discarded = true
        lock.unlock()
    }
}

/// The terminal and remote tab a create receipt bound a reservation to.
struct CloudTerminalReservationKey: Hashable {
    let resource: SurfaceResourceID
    let remoteTabID: String?
}

/// A native pane that already occupies the user's requested split or tab while
/// the machine creates the terminal behind it.
///
/// One reservation is one UI intent. The attachment adopts the pane when the
/// remote terminal resolves (`CmuxTuiSurfaceProvider.materialize(…, adopting:)`),
/// a failure is shown inside the pane, and the request is cancelled when the
/// user closes the pane first. While it waits the pane shows nothing but its
/// tab-strip spinner: no progress card, no placeholder text.
@MainActor
final class CloudTerminalPaneReservation {
    let workspaceID: UUID
    let panelID: UUID
    private(set) var sourcePlacement: CloudTerminalSourcePlacement
    /// An existing terminal's saved target, never the source tab of a new create.
    let attachmentPlacement: SurfaceResourcePlacement?
    /// The terminal this pane will show; never the split source. A new create
    /// has none until its receipt binds one, and until then no terminal may
    /// take this pane or its queued input.
    private(set) var boundResourceID: SurfaceResourceID?
    let creationReceipt = CloudTerminalCreationReceipt()
    let inputRelay: CloudOptimisticInputRelay
    let requestID: UUID?
    /// When the pane was inserted. Adoption hands the elapsed wait to the
    /// attachment session so the connection card does not restart its grace.
    let startedAt: ContinuousClock.Instant
    /// Replays the same request (create receipt first, then projection).
    var retry: (@MainActor () -> Void)?
    /// Cancels the local request; a remote terminal already created stays alive.
    var cancel: (@MainActor () -> Void)?

    init(
        workspaceID: UUID,
        panelID: UUID,
        machine: SurfaceMachineID,
        sourcePlacement: CloudTerminalSourcePlacement? = nil,
        attachmentPlacement: SurfaceResourcePlacement? = nil,
        inputRelay: CloudOptimisticInputRelay = CloudOptimisticInputRelay(),
        requestID: UUID? = nil,
        startedAt: ContinuousClock.Instant = .now
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.sourcePlacement = sourcePlacement ?? CloudTerminalSourcePlacement(
            machine: machine,
            remoteWorkspaceID: attachmentPlacement?.remoteWorkspaceID,
            remoteTabID: attachmentPlacement?.remoteTabID
        )
        self.attachmentPlacement = attachmentPlacement
        boundResourceID = attachmentPlacement?.resource
        self.inputRelay = inputRelay
        self.requestID = requestID
        self.startedAt = startedAt
    }

    var machine: SurfaceMachineID { sourcePlacement.machine }

    /// Records the create receipt: `sourcePlacement.resource` is now the created terminal.
    func bind(sourcePlacement: CloudTerminalSourcePlacement) {
        self.sourcePlacement = sourcePlacement
        boundResourceID = sourcePlacement.resource?.id
    }
    var remoteWorkspaceID: String? { sourcePlacement.remoteWorkspaceID }
    var remoteTabID: String? { sourcePlacement.remoteTabID }
    var elapsed: Duration { ContinuousClock.now - startedAt }

    /// Completes the workspace identity after the local pane was admitted.
    /// The pane can appear before the remote workspace receipt exists, so the
    /// source initially carries only its machine identity.
    func updateRemoteWorkspaceID(_ id: String) {
        sourcePlacement = CloudTerminalSourcePlacement(
            machine: sourcePlacement.machine,
            resource: sourcePlacement.resource,
            remoteWorkspaceID: id,
            remoteTabID: sourcePlacement.remoteTabID,
            pendingCreation: sourcePlacement.pendingCreation
        )
    }

    /// Rechecks a saved view after attachment awaits and before any queued input is forwarded.
    func validatedAttachmentPlacement(
        resourceID: SurfaceResourceID,
        remoteTabID: String?,
        materializedPlacement: SurfaceRemotePlacement? = nil,
        catalog: SurfaceCatalog
    ) throws -> SurfaceRemotePlacement? {
        guard let expected = attachmentPlacement else { return materializedPlacement }
        guard resourceID == expected.resource, resourceID.machine == machine,
              remoteTabID == nil || expected.remoteTabID == nil || remoteTabID == expected.remoteTabID else {
            throw CloudDiagnosticFailure.placement
        }
        guard expected.remoteWorkspaceID != nil || expected.remoteTabID != nil else { return materializedPlacement }
        guard let view = try? catalog.remoteView(
            for: resourceID, tabID: expected.remoteTabID, workspaceID: expected.remoteWorkspaceID
        ) else { throw CloudDiagnosticFailure.placement }
        if let materializedPlacement,
           materializedPlacement.workspaceID != view.workspace.id || materializedPlacement.tabID != view.tabID {
            throw CloudDiagnosticFailure.placement
        }
        return materializedPlacement ?? SurfaceRemotePlacement(workspaceID: view.workspace.id, tabID: view.tabID)
    }
}
