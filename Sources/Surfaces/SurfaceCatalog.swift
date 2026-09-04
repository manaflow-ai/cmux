import Foundation
import Observation

/// A provider owns the resources of one machine and knows how to put one on screen.
/// Providers push resource changes into the catalog (`catalog.replaceResources`) and the
/// catalog asks them to materialize a projection. They never track projections themselves.
@MainActor
protocol SurfaceProvider: AnyObject {
    var machine: SurfaceMachineID { get }
    var info: SurfaceMachineInfo { get }
    /// Whether this provider can materialize a machine port as a browser preview.
    /// Providers with a direct private-network URL may report true even when no
    /// control-plane `openPort` call is needed.
    var supportsPortPreviews: Bool { get }
    /// Re-sync from the source of truth (machine list, link snapshot, local panels).
    func refresh() async
    /// Re-sync this provider, optionally bypassing provider-side caches. The
    /// default preserves the legacy provider contract; cloud providers use the
    /// force bit for an explicit `--refresh` request.
    func refresh(force: Bool) async
    /// Create the pane that shows `resource` at `destination` and return the panel it created
    /// (or reused). The catalog records the projection.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Create a new terminal on this machine (remote providers create it in the cmux-tui
    /// session; the local provider spawns a shell) and return its resource.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource
    /// Called when a pane projecting one of this provider's resources goes away. Remote
    /// providers do nothing (the resource lives on); the local provider drops the resource.
    func projectionDidEnd(_ projection: SurfaceProjection)
    /// End a terminal on this machine (the process and its remote tab). Providers that
    /// cannot (the local machine) throw `SurfaceCatalogError.unsupported`.
    func closeTerminal(_ id: SurfaceResourceID) async throws
    /// Create a new, empty workspace on this machine, directly (not as a side effect of
    /// creating a terminal). Providers without remote workspaces refuse.
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace
    /// Close a workspace view on this machine. Its terminals detach into the pool
    /// (`spec/cli.md`: only `terminal close` kills); callers wanting a full delete
    /// close each terminal first.
    func closeRemoteWorkspace(id: String) async throws
    /// Rename a remote workspace.
    func renameRemoteWorkspace(id: String, name: String) async throws
    /// Close a projection's pane: a materialization that lost a race with an existing
    /// projection, or a URL-backed pane whose machine was unregistered. The default
    /// implementation handles providers that use the shared pane factory; providers may
    /// also clear provider-specific bookkeeping. Return true when the provider preserved
    /// the projection, as the local provider does for a moved pane.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool
}

extension SurfaceProvider {
    /// Legacy providers predate the capability bit and are assumed to support
    /// previews until their concrete implementation says otherwise.
    var supportsPortPreviews: Bool { true }

    func refresh(force: Bool) async {
        await refresh()
    }

    func closeTerminal(_ id: SurfaceResourceID) async throws {
        throw SurfaceCatalogError.unsupported("closing terminals on \(machine)")
    }
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        throw SurfaceCatalogError.unsupported("workspaces on \(machine)")
    }
    func closeRemoteWorkspace(id: String) async throws {
        throw SurfaceCatalogError.unsupported("closing workspaces on \(machine)")
    }
    func renameRemoteWorkspace(id: String, name: String) async throws {
        throw SurfaceCatalogError.unsupported("workspaces on \(machine)")
    }
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}

/// The single owner of surface identities and projections on this Mac.
///
/// Rules that hold by construction:
/// - a resource exists in exactly one provider's machine and appears once in `resources`;
/// - a projection is (resource, workspace, panel) and is recorded only by the catalog, when
///   a provider materializes a pane or when an existing pane is adopted at startup/restore;
/// - `project(_:into:)` is the only open path: if the resource is already projected and
///   the caller allows reuse, the existing pane is focused instead of duplicated.
@MainActor
@Observable
final class SurfaceCatalog {
    static let shared = SurfaceCatalog()

    /// A provider call with no remaining caller must not occupy a resource forever when the
    /// provider ignores task cancellation. The deadline starts only after the last caller
    /// detaches, so a slow but observed materialization is still allowed to finish normally.
    nonisolated static let defaultAbandonedMaterializationTimeout: Duration = .seconds(30)
    nonisolated static let defaultRetiredMaterializationRetention: Duration = .seconds(30)
    nonisolated static let defaultCompletedMaterializationRetention: Duration = .seconds(30)
    /// The coordinator never allows more than this many tasks from one machine to remain tracked
    /// while cancellation is unresolved. This prevents one unhealthy machine from blocking
    /// unrelated machines while also bounding repeated provider replacements.
    nonisolated static let defaultMaximumTrackedMaterializations = 16

    static let didChangeNotification = Notification.Name("cmux.surfaces.didChange")

    private(set) var machines: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    private(set) var resources: [SurfaceResourceID: SurfaceResource] = [:]
    private(set) var projections: Set<SurfaceProjection> = []
    /// The last accepted revision for each cloud daemon.  A snapshot with an older
    /// revision is never allowed to replace the rows that a newer snapshot published.
    private var cloudCursors: [SurfaceMachineID: CloudVMCursor] = [:]
    /// Daemon generations are opaque and cannot be ordered, but a generation that has
    /// already been accepted is still distinguishable from a newly connected daemon.
    /// Retaining the seen set prevents a delayed response from an older link from
    /// time-travelling the catalog after a reconnect established a new generation.
    private var cloudGenerationsByMachine: [SurfaceMachineID: Set<String>] = [:]
    /// Fingerprint of the workspace identity/name graph at the last accepted
    /// cursor. Equal cursors with different payloads are protocol-inconsistent;
    /// rejecting them prevents a delayed duplicate response from restoring an
    /// old name after the matching rename snapshot was already accepted.
    private var cloudCursorFingerprints: [SurfaceMachineID: (cursor: CloudVMCursor, value: String)] = [:]
    /// Local write intents stay in the catalog until a remote snapshot confirms them.  This
    /// is deliberately keyed by stable machine/workspace ids, never by a display name.
    private var cloudWorkspaceRenameIntents: [CloudWorkspaceRenameKey: CloudWorkspaceRenameIntent] = [:]
    private var nextCloudWorkspaceRenameSequence: UInt64 = 0
    /// One serialized lane per remote identity, shared by the tree, socket, and local-title
    /// entry points.
    let cloudWorkspaceRenameCoordinator = CloudWorkspaceRenameCoordinator()
    /// Resource IDs grouped by machine so providers can answer presence checks
    /// without sorting the full catalog snapshot on every refresh.
    private var resourceIDsByMachine: [SurfaceMachineID: Set<SurfaceResourceID>] = [:]
    private var providers: [SurfaceMachineID: any SurfaceProvider] = [:]
    /// Materializations are asynchronous, so actor reentrancy can otherwise let two callers
    /// pass the reuse check before either provider has returned a projection.
    private var inFlightProjects: [SurfaceResourceID: SurfaceProjectionMaterialization] = [:]
    /// Tokens for operations that can still report after the catalog moved on. The provider is
    /// held by the provider task itself and passed to the late-result callback, so these sets do
    /// not keep disconnected providers alive. Every token has one bounded eviction task.
    private var retiredMaterializationTokens: Set<UUID> = []
    private var retiredMaterializationEvictionTasks: [UUID: Task<Void, Never>] = [:]
    private var trackedMaterializationTokens: Set<UUID> = []
    private var trackedMaterializationMachines: [UUID: SurfaceMachineID] = [:]
    private var trackedMaterializationCounts: [SurfaceMachineID: Int] = [:]
    private let retiredMaterializationRetention: Duration
    private let completedMaterializationRetention: Duration
    private let abandonedMaterializationTimeout: Duration
    private let maximumTrackedMaterializations: Int
    private let materializationClock: any Clock<Duration>
    /// Panels whose projection was recorded from a restored session before the provider
    /// re-synced; resolved into `projections` once the resource shows up.
    private var pendingRestoredProjections: [SurfaceProjectionRecord: UUID] = [:]

    /// Focus/select behavior the app uses to bring an existing projection forward.
    var focusProjection: ((SurfaceProjection) -> Void)?

    init(
        abandonedMaterializationTimeout: Duration = SurfaceCatalog.defaultAbandonedMaterializationTimeout,
        retiredMaterializationRetention: Duration = SurfaceCatalog.defaultRetiredMaterializationRetention,
        completedMaterializationRetention: Duration = SurfaceCatalog.defaultCompletedMaterializationRetention,
        maximumTrackedMaterializations: Int = SurfaceCatalog.defaultMaximumTrackedMaterializations,
        materializationClock: any Clock<Duration> = ContinuousClock()
    ) {
        precondition(abandonedMaterializationTimeout > .zero)
        precondition(retiredMaterializationRetention > .zero)
        precondition(completedMaterializationRetention > .zero)
        precondition(maximumTrackedMaterializations > 0)
        self.abandonedMaterializationTimeout = abandonedMaterializationTimeout
        self.retiredMaterializationRetention = retiredMaterializationRetention
        self.completedMaterializationRetention = completedMaterializationRetention
        self.maximumTrackedMaterializations = maximumTrackedMaterializations
        self.materializationClock = materializationClock
    }

    // MARK: Providers

    func register(_ provider: any SurfaceProvider) {
        if let previous = providers[provider.machine], previous !== provider {
            let inFlightIDs = inFlightProjects.keys.filter { $0.machine == provider.machine }
            for id in inFlightIDs {
                cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
            }
        }
        providers[provider.machine] = provider
        var info = provider.info
        if !provider.machine.isLocal {
            preserveCanonicalCloudWorkspaceNames(in: &info)
            overlayPendingCloudWorkspaceRenames(machine: provider.machine, info: &info)
        }
        machines[provider.machine] = info
        notifyChange()
    }

    func unregister(machine: SurfaceMachineID) {
        let inFlightIDs = inFlightProjects.keys.filter { $0.machine == machine }
        for id in inFlightIDs {
            cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
        }
        // A machine that is gone (deleted, or access ended) takes its URL-backed
        // panes with it: a display or browser pane holds a tokened gateway URL
        // that decays into the hosting provider's raw error page once the
        // workload is dead. Terminal panes stay — their attach process exits and
        // the scrollback is still the user's to read.
        let urlBacked = projections.filter {
            $0.resource.machine == machine
                && ($0.resource.kind == .display || $0.resource.kind == .browser)
        }
        let provider = providers[machine]
        for projection in urlBacked {
            if let provider {
                provider.discardMaterialization(projection)
            } else {
                // The registry removes its provider before calling us during a
                // fleet prune. There is still a real browser/display pane to
                // close, even though no provider remains to do it for us.
                SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
            }
        }
        providers[machine] = nil
        machines[machine] = nil
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        let pending = pendingRestoredProjections.keys.filter { $0.resource.machine == machine }
        for record in pending { pendingRestoredProjections[record] = nil }
        projections = projections.filter { $0.resource.machine != machine }
        cloudCursors[machine] = nil
        cloudGenerationsByMachine[machine] = nil
        cloudCursorFingerprints[machine] = nil
        cloudWorkspaceRenameIntents = cloudWorkspaceRenameIntents.filter { $0.key.machine != machine }
        notifyChange()
    }

    func provider(for machine: SurfaceMachineID) -> (any SurfaceProvider)? {
        providers[machine]
    }

    /// Only the registered provider of a cloud machine (or the local provider,
    /// registered at launch) may write about it. A provider the fleet has just
    /// pruned can still finish an in-flight refresh and write its machine back;
    /// accepting that write brings a machine the backend already destroyed back
    /// as a sidebar row nothing can refresh or delete.
    private func accepts(writeFor machine: SurfaceMachineID, from source: (any SurfaceProvider)? = nil) -> Bool {
        if machine.isLocal { return true }
        guard let registered = providers[machine] else {
#if DEBUG
            cmuxDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=unregistered")
#endif
            return false
        }
        // Cloud providers refresh asynchronously. Once a replacement is
        // registered, a late callback from the retired instance must not write
        // through the replacement's catalog entry. Callers that do not have a
        // provider (legacy socket paths) retain the current-provider behavior.
        if let source,
           (source.machine != machine || ObjectIdentifier(registered) != ObjectIdentifier(source)) {
#if DEBUG
            cmuxDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=retired-provider")
#endif
            return false
        }
        return true
    }

    /// Refreshes one machine without waiting on unrelated cloud links. A
    /// machine-scoped CLI request must not be held hostage by another VM's
    /// reconnect timeout.
    func refresh(machine: SurfaceMachineID, force: Bool = false) async {
        guard let provider = providers[machine] else { return }
        await provider.refresh(force: force)
    }

    func refreshAll(force: Bool = false) async {
        for provider in providers.values {
            await provider.refresh(force: force)
        }
    }

    // MARK: Resources (called by providers)

    /// Returns the last accepted daemon cursor for `machine`, if the provider has published
    /// a versioned snapshot.  A missing cursor means the connected daemon is legacy and cannot
    /// safely accept a compare-and-swap rename.
    func cloudCursor(for machine: SurfaceMachineID) -> CloudVMCursor? {
        cloudCursors[machine]
    }

    /// Records a user rename intent and applies it to every catalog projection immediately.
    /// The returned token is required to commit or roll the intent back; an older completion
    /// can therefore never undo a newer edit.
    @discardableResult
    func beginCloudWorkspaceRename(
        machine: SurfaceMachineID,
        workspaceID: String,
        name: String
    ) throws -> CloudWorkspaceRenameToken {
        guard case .cloud = machine else {
            throw SurfaceCatalogError.unsupported(String(
                localized: "cloudTree.error.renameLocalUnsupported",
                defaultValue: "Only cloud workspaces can be renamed through this path."
            ))
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SurfaceCatalogError.unsupported(String(
                localized: "cloudTree.error.renameWorkspaceEmpty",
                defaultValue: "A cloud workspace name cannot be empty."
            ))
        }
        let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)
        // A queued edit is based on the same canonical value as its predecessor,
        // not on that predecessor's optimistic overlay. Otherwise two failed
        // edits can roll back to an uncommitted intermediate label.
        let previousName = cloudWorkspaceRenameIntents[key]?.previousName
            ?? remoteWorkspaceName(machine: machine, workspaceID: workspaceID)
        guard let previousName else {
            throw SurfaceCatalogError.destinationNotFound(
                String(
                    format: String(
                        localized: "cloudTree.error.renameWorkspaceMissing",
                        defaultValue: "workspace %@ on %@"
                    ),
                    workspaceID,
                    machine.rawValue
                )
            )
        }
        nextCloudWorkspaceRenameSequence &+= 1
        let token = CloudWorkspaceRenameToken(
            key: key,
            sequence: nextCloudWorkspaceRenameSequence,
            previousName: previousName,
            baselineCursor: cloudCursors[machine]
        )
        cloudWorkspaceRenameIntents[key] = CloudWorkspaceRenameIntent(
            sequence: token.sequence,
            name: normalized,
            previousName: previousName,
            baselineCursor: token.baselineCursor,
            receiptCursor: nil,
            observedName: nil,
            observedCursor: nil
        )
        applyRemoteWorkspaceName(machine: machine, workspaceID: workspaceID, name: normalized)
        return token
    }

    /// Marks a submitted rename as accepted at `receipt`, while retaining its optimistic
    /// overlay until a complete snapshot confirms the graph.  A malformed or regressive receipt
    /// is ignored by the caller before this method is reached.
    func commitCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken, receipt: CloudVMCursor?) {
        let acceptedReceipt: CloudVMCursor?
        if let receipt,
           let current = cloudCursors[token.key.machine],
           current.generation == receipt.generation,
           receipt.revision >= current.revision {
            // The receipt is a complete daemon commit position.  Advancing the CAS base here
            // lets a queued rename use the new revision without pretending that unrelated row
            // details are already refreshed; the following snapshot supplies those details.
            cloudCursors[token.key.machine] = receipt
            cloudCursorFingerprints[token.key.machine] = nil
            acceptedReceipt = receipt
        } else {
            acceptedReceipt = nil
        }
        if let acceptedReceipt,
           var newer = cloudWorkspaceRenameIntents[token.key],
           newer.sequence > token.sequence {
            // A newer local edit is intentionally serialized behind this one. Move
            // only that edit's CAS base to this receipt; an external snapshot does
            // not get treated as a predecessor and therefore cannot be overwritten.
            newer.baselineCursor = acceptedReceipt
            newer.receiptCursor = nil
            newer.observedName = nil
            newer.observedCursor = nil
            cloudWorkspaceRenameIntents[token.key] = newer
        }
        guard var intent = cloudWorkspaceRenameIntents[token.key], intent.sequence == token.sequence else { return }
        intent.receiptCursor = acceptedReceipt
        intent.observedName = nil
        intent.observedCursor = nil
        cloudWorkspaceRenameIntents[token.key] = intent
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: intent.name
        )
    }

    /// Whether a rename token is still the newest local intent for its identity.
    func isCurrentCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) -> Bool {
        cloudWorkspaceRenameIntents[token.key]?.sequence == token.sequence
    }

    /// Rolls an intent back only when it is still the newest intent for its identity.
    func rollbackCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) {
        guard let intent = cloudWorkspaceRenameIntents[token.key], intent.sequence == token.sequence else { return }
        cloudWorkspaceRenameIntents[token.key] = nil
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: intent.previousName
        )
    }

    /// Resolves a failed/uncertain submission after the provider has attempted a
    /// fresh read. If that read observed a canonical name, accept it—even when
    /// its generation differs—because the optimistic overlay is no longer a
    /// safe source of truth. Without an observed graph, leave the intent pending.
    func resolveFailedCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) {
        guard let intent = cloudWorkspaceRenameIntents[token.key], intent.sequence == token.sequence else {
            return
        }
        let name: String
        if let observedName = intent.observedName {
            name = observedName
        } else if intent.observedCursor != nil {
            // The fresh graph was accepted but no longer contains this
            // workspace. Restore the predecessor in any detached local
            // projection; retaining the requested label would be misleading.
            name = intent.previousName
        } else if let current = cloudCursors[token.key.machine],
                  let baseline = intent.receiptCursor ?? intent.baselineCursor,
                  current == baseline {
            // No accepted snapshot followed the submission; the catalog is
            // still exactly at the compare-and-swap base, so restoring the
            // canonical predecessor is safe.
            name = intent.previousName
        } else {
            return
        }
        cloudWorkspaceRenameIntents[token.key] = nil
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: name
        )
    }

    /// Returns the optimistic name currently held for an identity, if any.
    func pendingCloudWorkspaceRenameName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        cloudWorkspaceRenameIntents[CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)]?.name
    }

    /// Returns the compare-and-swap cursor a rename token may submit against.
    ///
    /// A newer local intent may supersede `token` while the coordinator is waiting;
    /// the older operation still runs first, but only at its original cursor. Once
    /// that operation commits, ``commitCloudWorkspaceRename`` advances the newer
    /// intent's baseline to the receipt. This prevents a queued local edit from
    /// being silently rebased over an unrelated remote writer.
    func cloudWorkspaceRenameSubmissionCursor(_ token: CloudWorkspaceRenameToken) -> CloudVMCursor? {
        guard let currentIntent = cloudWorkspaceRenameIntents[token.key],
              currentIntent.sequence >= token.sequence,
              let baseline = token.sequence == currentIntent.sequence
                  ? (currentIntent.receiptCursor ?? currentIntent.baselineCursor)
                  : token.baselineCursor,
              let current = cloudCursors[token.key.machine],
              current == baseline else {
            return nil
        }
        return current
    }

    /// Whether a token still belongs to a live local rename lane. This is broader
    /// than ``isCurrentCloudWorkspaceRename`` because an older operation must be
    /// allowed to finish before a newer queued operation can use its receipt.
    func hasCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) -> Bool {
        guard let intent = cloudWorkspaceRenameIntents[token.key] else { return false }
        return intent.sequence >= token.sequence
    }

    /// Installs a complete cloud snapshot as one transaction.  The cursor fence is applied
    /// before any row is removed, and pending local names are merged into all projections before
    /// the catalog publishes its single change notification.
    @discardableResult
    func replaceCloudResources(
        _ list: [SurfaceResource],
        on machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        cursor: CloudVMCursor?,
        from source: (any SurfaceProvider)? = nil
    ) -> Bool {
        guard accepts(writeFor: machine, from: source) else { return false }
        guard case .cloud = machine else {
            return replaceResources(list, on: machine, info: info, from: source)
        }
        // Once a versioned graph has been observed, a cursorless or older read is a stale
        // compatibility response, not permission to erase the current graph.
        if let cursor {
            if cloudGenerationsByMachine[machine]?.contains(cursor.generation) == true,
               cloudCursors[machine]?.generation != cursor.generation {
                // Generation identifiers are opaque, so a previously accepted
                // generation is the only reliable evidence that this response
                // came from an older link. Do not let it replace a reconnect's
                // graph merely because its revision is numerically larger.
                return false
            }
            if let current = cloudCursors[machine], cursor.generation == current.generation {
                guard cursor.revision >= current.revision else { return false }
            }
        } else if cloudCursors[machine] != nil {
            return false
        }

        var mergedInfo = info
        var mergedResources = list
        let incomingFingerprint = cloudWorkspaceGraphFingerprint(info: info, resources: list)
        if let cursor,
           let existing = cloudCursorFingerprints[machine],
           existing.cursor == cursor,
           existing.value != incomingFingerprint {
            // A cursor identifies one immutable graph cut. Do not let a stale
            // response with the same cursor but an older payload time-travel
            // the catalog; callers will receive the next authoritative refresh.
            return false
        }
        reconcilePendingCloudWorkspaceRenames(
            machine: machine,
            cursor: cursor,
            info: &mergedInfo,
            resources: &mergedResources
        )
        // Fingerprint the graph that will actually be published, including any
        // pending optimistic name overlay. Otherwise a stale payload accepted
        // while a rename receipt is in flight can poison the equal-cursor fence
        // and cause the subsequent canonical payload to be rejected.
        let acceptedFingerprint = cloudWorkspaceGraphFingerprint(
            info: mergedInfo,
            resources: mergedResources
        )

        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        for resource in mergedResources {
            precondition(
                resource.machine == machine,
                "resource " + resource.id.rawValue + " reported by the wrong provider"
            )
            resources[resource.id] = resource
            resourceIDsByMachine[machine, default: []].insert(resource.id)
        }
        machines[machine] = mergedInfo
        if let cursor {
            cloudCursors[machine] = cursor
            cloudGenerationsByMachine[machine, default: []].insert(cursor.generation)
            cloudCursorFingerprints[machine] = (cursor: cursor, value: acceptedFingerprint)
        }
        resolvePendingRestoredProjections(on: machine)
        CloudWorkspaceRenameWriteThrough.reconcileRemoteProjections(catalog: self)
        notifyChange()
        return true
    }

    /// Replace everything the catalog knows about one machine. Projections whose resource
    /// disappeared are kept only if the pane still exists (the pane shows an exited/unknown
    /// terminal until it is closed); the caller prunes dead panes through `endProjection`.
    /// `from` identifies the provider that produced the snapshot, when one is available.
    @discardableResult
    func replaceResources(_ list: [SurfaceResource], on machine: SurfaceMachineID, info: SurfaceMachineInfo? = nil, from source: (any SurfaceProvider)? = nil) -> Bool {
        if !machine.isLocal, let info {
            return replaceCloudResources(list, on: machine, info: info, cursor: nil, from: source)
        }
        guard accepts(writeFor: machine, from: source) else { return false }
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong provider")
            resources[resource.id] = resource
            resourceIDsByMachine[machine, default: []].insert(resource.id)
        }
        if let info { machines[machine] = info }
        resolvePendingRestoredProjections(on: machine)
        notifyChange()
        return true
    }

    /// Insert or replace one resource. A cloud provider may identify itself with `from` so a
    /// result from a retired provider cannot overwrite a replacement registration.
    func upsert(_ resource: SurfaceResource, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: resource.machine, from: source) else { return }
        var adjusted = resource
        if !resource.machine.isLocal {
            overlayPendingCloudWorkspaceRenames(machine: resource.machine, resource: &adjusted)
        }
        resources[resource.id] = adjusted
        resourceIDsByMachine[resource.machine, default: []].insert(resource.id)
        resolvePendingRestoredProjections(on: resource.machine)
        notifyChange()
    }

    /// Remove a resource, optionally validating the provider that requested the mutation.
    func remove(_ id: SurfaceResourceID, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: id.machine, from: source) else { return }
        resources[id] = nil
        resourceIDsByMachine[id.machine]?.remove(id)
        if resourceIDsByMachine[id.machine]?.isEmpty == true {
            resourceIDsByMachine[id.machine] = nil
        }
        notifyChange()
    }

    /// Update machine metadata, optionally validating the provider registration that supplied it.
    func updateMachine(_ info: SurfaceMachineInfo, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: info.id, from: source) else { return }
        var adjusted = info
        if !info.id.isLocal {
            preserveCanonicalCloudWorkspaceNames(in: &adjusted)
            overlayPendingCloudWorkspaceRenames(machine: info.id, info: &adjusted)
        }
        machines[info.id] = adjusted
        if !info.id.isLocal {
            CloudWorkspaceRenameWriteThrough.reconcileRemoteProjections(catalog: self)
        }
        notifyChange()
    }

    /// Keeps a status/metadata write from time-travelling the identity graph.
    ///
    /// Machine summaries do not carry the session cursor, so a provider update can
    /// arrive after a newer snapshot (or a rename receipt) has already been accepted.
    /// Preserve the canonical name for identities present in both graphs; new and
    /// removed workspace ids remain visible until the next authoritative snapshot.
    /// A nil incoming list is likewise an unknown graph, never an instruction to erase it.
    private func preserveCanonicalCloudWorkspaceNames(in info: inout SurfaceMachineInfo) {
        guard !info.id.isLocal,
              cloudCursors[info.id] != nil,
              let canonical = machines[info.id]?.remoteWorkspaces else { return }
        guard let incoming = info.remoteWorkspaces else {
            info.remoteWorkspaces = canonical
            return
        }
        let canonicalByID = Dictionary(
            canonical.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        info.remoteWorkspaces = incoming.map { workspace in
            guard let current = canonicalByID[workspace.id], current.name != workspace.name else {
                return workspace
            }
            var adjusted = workspace
            adjusted.name = current.name
            return adjusted
        }
    }

    /// Finds a workspace name from the machine projection first, then from resource views.
    /// Both paths are keyed by the daemon id and intentionally refuse name-based matching.
    private func remoteWorkspaceName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        var names = Set<String>()
        if let matches = machines[machine]?.remoteWorkspaces?.filter({ $0.id == workspaceID }) {
            guard matches.count <= 1 else { return nil }
            names.formUnion(matches.map(\.name))
        }
        for id in resourceIDsByMachine[machine] ?? [] {
            for workspace in resources[id]?.remoteWorkspaces ?? [] where workspace.id == workspaceID {
                names.insert(workspace.name)
            }
        }
        guard names.count == 1 else { return nil }
        return names.first
    }

    /// Applies one canonical workspace name to the machine metadata and every nested resource
    /// view.  This is the only fan-out mutation; views never maintain a second copy.
    private func applyRemoteWorkspaceName(machine: SurfaceMachineID, workspaceID: String, name: String) {
        var changed = false
        if var info = machines[machine], let workspaces = info.remoteWorkspaces {
            let updated = workspaces.map { workspace -> SurfaceRemoteWorkspace in
                guard workspace.id == workspaceID, workspace.name != name else { return workspace }
                var renamed = workspace
                renamed.name = name
                changed = true
                return renamed
            }
            if updated != workspaces {
                info.remoteWorkspaces = updated
                machines[machine] = info
            }
        }
        for id in resourceIDsByMachine[machine] ?? [] {
            guard var resource = resources[id] else { continue }
            var resourceChanged = false
            if var workspace = resource.remoteWorkspace, workspace.id == workspaceID, workspace.name != name {
                workspace.name = name
                resource.remoteWorkspace = workspace
                resourceChanged = true
            }
            if let views = resource.remoteViews {
                let updatedViews = views.map { view -> SurfaceRemoteView in
                    guard view.workspace.id == workspaceID, view.workspace.name != name else { return view }
                    var renamed = view
                    renamed.workspace.name = name
                    resourceChanged = true
                    return renamed
                }
                if updatedViews != views {
                    resource.remoteViews = updatedViews
                }
            }
            if resourceChanged {
                resources[id] = resource
                changed = true
            }
        }
        if changed {
            CloudWorkspaceRenameWriteThrough.reconcileRemoteProjections(catalog: self)
            notifyChange()
        }
    }

    /// Overlays pending intents on a metadata update that has no ordering cursor (for example
    /// a fleet status update). This never clears an intent because the update cannot prove a
    /// newer daemon graph.
    private func overlayPendingCloudWorkspaceRenames(
        machine: SurfaceMachineID,
        info: inout SurfaceMachineInfo
    ) {
        let intents = cloudWorkspaceRenameIntents.filter { $0.key.machine == machine }
        guard !intents.isEmpty else { return }
        for (key, intent) in intents {
            guard key.machine == machine else { continue }
            info.remoteWorkspaces = info.remoteWorkspaces?.map { workspace in
                guard workspace.id == key.workspaceID else { return workspace }
                var renamed = workspace
                renamed.name = intent.name
                return renamed
            }
        }
    }

    private func overlayPendingCloudWorkspaceRenames(
        machine: SurfaceMachineID,
        resource: inout SurfaceResource
    ) {
        for (key, intent) in cloudWorkspaceRenameIntents where key.machine == machine {
            if var workspace = resource.remoteWorkspace, workspace.id == key.workspaceID {
                workspace.name = intent.name
                resource.remoteWorkspace = workspace
            }
            resource.remoteViews = resource.remoteViews?.map { view in
                guard view.workspace.id == key.workspaceID else { return view }
                var adjusted = view
                adjusted.workspace.name = intent.name
                return adjusted
            }
        }
    }

    /// Merges pending intents into an incoming snapshot and retires them only when the incoming
    /// cursor proves that the daemon has observed the write. A new daemon generation is a fresh
    /// authoritative lineage; an older same-generation cursor is rejected before this method.
    private func reconcilePendingCloudWorkspaceRenames(
        machine: SurfaceMachineID,
        cursor: CloudVMCursor?,
        info: inout SurfaceMachineInfo,
        resources: inout [SurfaceResource]
    ) {
        let keys = cloudWorkspaceRenameIntents.keys.filter { $0.machine == machine }
        for key in keys {
            guard var intent = cloudWorkspaceRenameIntents[key] else { continue }
            let incomingName = Self.remoteWorkspaceName(
                workspaceID: key.workspaceID,
                info: info,
                resources: resources
            )
            var overlay = true
            var clear = false
            if let cursor {
                // Capture the unoverlaid value before deciding whether the
                // intent should remain visible. This is the only observation
                // available to an uncertain-failure resolver after we merge
                // the optimistic name into the stored graph.
                intent.observedName = incomingName
                intent.observedCursor = cursor
                cloudWorkspaceRenameIntents[key] = intent
                let baseline = intent.receiptCursor ?? intent.baselineCursor
                if let baseline, cursor.generation == baseline.generation {
                    if incomingName == intent.name {
                        // The daemon graph contains the requested value. This is
                        // sufficient confirmation at the baseline or any newer
                        // revision and lets the optimistic overlay retire.
                        overlay = false
                        clear = true
                    } else if cursor.revision > baseline.revision {
                        // A strictly newer same-generation graph with a different
                        // name belongs to another writer. Its revision is ordered
                        // evidence, so accept that writer rather than repeatedly
                        // retrying an intent that lost a compare-and-swap race.
                        overlay = false
                        clear = true
                    }
                } else if incomingName == intent.name {
                    // Revisions from different daemon generations are not
                    // comparable, but a matching name is an unambiguous receipt.
                    overlay = false
                    clear = true
                } else {
                    // Reconnect snapshots from a different generation may be
                    // stale while a just-committed rename is still replaying.
                    // Keep the optimistic value until the generation reports
                    // the requested name or an in-flight operation explicitly
                    // resolves the uncertainty. Old generations are fenced
                    // before reaching this method.
                }
            }
            if overlay {
                Self.applyRemoteWorkspaceName(
                    workspaceID: key.workspaceID,
                    name: intent.name,
                    info: &info,
                    resources: &resources
                )
            }
            if clear { cloudWorkspaceRenameIntents[key] = nil }
        }
    }

    private static func remoteWorkspaceName(
        workspaceID: String,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource]
    ) -> String? {
        var names = Set<String>()
        if let matches = info.remoteWorkspaces?.filter({ $0.id == workspaceID }) {
            guard matches.count <= 1 else { return nil }
            names.formUnion(matches.map(\.name))
        }
        for resource in resources {
            names.formUnion(resource.remoteWorkspaces.filter { $0.id == workspaceID }.map(\.name))
        }
        return names.count == 1 ? names.first : nil
    }

    private static func applyRemoteWorkspaceName(
        workspaceID: String,
        name: String,
        info: inout SurfaceMachineInfo,
        resources: inout [SurfaceResource]
    ) {
        info.remoteWorkspaces = info.remoteWorkspaces?.map { workspace in
            guard workspace.id == workspaceID else { return workspace }
            var renamed = workspace
            renamed.name = name
            return renamed
        }
        resources = resources.map { resource in
            var adjusted = resource
            if var workspace = adjusted.remoteWorkspace, workspace.id == workspaceID {
                workspace.name = name
                adjusted.remoteWorkspace = workspace
            }
            adjusted.remoteViews = adjusted.remoteViews?.map { view in
                guard view.workspace.id == workspaceID else { return view }
                var adjustedView = view
                adjustedView.workspace.name = name
                return adjustedView
            }
            return adjusted
        }
    }

    /// Encodes only the identity-bearing portion of a cloud snapshot. Machine
    /// status, statistics, and port discovery may change without advancing the
    /// daemon workspace cursor; workspace ids, names, and placements may not.
    private func cloudWorkspaceGraphFingerprint(
        info: SurfaceMachineInfo,
        resources: [SurfaceResource]
    ) -> String {
        var parts: [String] = []
        let workspaces = (info.remoteWorkspaces ?? []).sorted {
            $0.id != $1.id ? $0.id < $1.id : $0.index < $1.index
        }
        for workspace in workspaces {
            parts.append("w:\(workspace.id.count):\(workspace.id):\(workspace.name.count):\(workspace.name):\(workspace.index):\(workspace.focused ? 1 : 0)")
        }
        for resource in resources.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let views = (resource.remoteViews ?? []).sorted {
                $0.tabID != $1.tabID ? $0.tabID < $1.tabID : $0.workspace.id < $1.workspace.id
            }
            parts.append("r:\(resource.id.rawValue.count):\(resource.id.rawValue)")
            if let workspace = resource.remoteWorkspace {
                parts.append("p:\(workspace.id.count):\(workspace.id):\(workspace.name.count):\(workspace.name)")
            } else {
                parts.append("p:")
            }
            for view in views {
                parts.append("v:\(view.tabID.count):\(view.tabID):\(view.workspace.id.count):\(view.workspace.id):\(view.workspace.name.count):\(view.workspace.name)")
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: Projections

    /// The only open path. Reuses an existing projection when `reuseExisting` is set and one
    /// exists (focusing it), otherwise asks the provider to materialize a pane.
    ///
    /// `reuseInWorkspace` narrows reuse to projections in that local workspace: a pane
    /// showing the resource in ANOTHER workspace neither satisfies the open nor steals
    /// focus — the resource materializes at `destination` instead. A workspace's own
    /// Desktop row uses this so "open this workspace's screen" never teleports to a
    /// different workspace's VNC pane. Nil keeps the global open-or-focus jump.
    @discardableResult
    func project(_ id: SurfaceResourceID, into destination: SurfaceDestination, focus: Bool = true, reuseExisting: Bool = true, reuseInWorkspace: UUID? = nil) async throws -> (projection: SurfaceProjection, reused: Bool) {
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        if reuseExisting, let existing = projections.first(where: { $0.resource == id && (reuseInWorkspace == nil || $0.workspaceID == reuseInWorkspace) }) {
            try claimCompletedMaterializationIfNeeded(id, projection: existing)
            if focus { focusProjection?(existing) }
            return (existing, true)
        }
        guard let provider = providers[id.machine] else { throw SurfaceCatalogError.noProvider(id.machine) }

        // Workspace-scoped reuse missed: an in-flight materialization bound elsewhere
        // must not be adopted either (it would land — and focus — in that other
        // workspace), so scoped calls go straight to a fresh materialization.
        if reuseExisting, reuseInWorkspace == nil {
            let waiterID = UUID()
            let result = try await withTaskCancellationHandler {
                try await awaitMaterialization(
                    id: id,
                    resource: resource,
                    provider: provider,
                    destination: destination,
                    focus: focus,
                    waiterID: waiterID
                )
            } onCancel: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.cancelInFlightProjectWaiter(id, waiterID: waiterID)
                }
            }
            return try finalizeMaterializationWaiter(
                id: id,
                waiterID: waiterID,
                result: result,
                focus: focus
            )
        }

        let projection = try await provider.materialize(resource, at: destination, focus: focus)
        record(projection)
        return (projection, false)
    }

    private func awaitMaterialization(
        id: SurfaceResourceID,
        resource: SurfaceResource,
        provider: any SurfaceProvider,
        destination: SurfaceDestination,
        focus: Bool,
        waiterID: UUID
    ) async throws -> SurfaceProjectionMaterialization.Result {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }

            if let inFlight = inFlightProjects[id], let completedProjection = inFlight.completedProjection {
                var completed = inFlight
                completed.pendingAcknowledgements.insert(waiterID)
                inFlightProjects[id] = completed
                continuation.resume(returning: (projection: completedProjection, reused: true))
                return
            }
            if let inFlight = inFlightProjects[id], inFlight.provider !== provider {
                cancelInFlightProject(id, error: SurfaceCatalogError.unknownResource(id))
            }
            if var inFlight = inFlightProjects[id] {
                inFlight.abandoned = false
                inFlight.abandonmentDeadlineTask?.cancel()
                inFlight.abandonmentDeadlineTask = nil
                inFlight.waiters[waiterID] = (reused: true, continuation: continuation)
                inFlightProjects[id] = inFlight
                return
            }

            guard trackedMaterializationCounts[provider.machine, default: 0] < maximumTrackedMaterializations else {
                continuation.resume(throwing: SurfaceCatalogError.unavailable(id, reason: "materialization capacity exhausted"))
                return
            }

            let token = UUID()
            trackMaterialization(token, for: provider)
            let task = Task { @MainActor [weak self] in
                do {
                    let projection = try await provider.materialize(resource, at: destination, focus: focus)
                    self?.finishInFlightProject(id, token: token, provider: provider, result: .success(projection))
                } catch {
                    self?.finishInFlightProject(id, token: token, provider: provider, result: .failure(error))
                }
            }
            inFlightProjects[id] = SurfaceProjectionMaterialization(
                token: token,
                provider: provider,
                task: task,
                abandonmentDeadlineTask: nil,
                waiters: [waiterID: (reused: false, continuation: continuation)],
                completedProjection: nil,
                completionOwnsProjection: false,
                pendingAcknowledgements: [],
                completionCleanupTask: nil
            )
        }
    }

    private func finishInFlightProject(
        _ id: SurfaceResourceID,
        token: UUID,
        provider: any SurfaceProvider,
        result: Result<SurfaceProjection, any Error>
    ) {
        guard var inFlight = inFlightProjects[id], inFlight.token == token else {
            releaseTrackedMaterialization(token)
            if retiredMaterializationTokens.remove(token) != nil {
                retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
            }
            if case .success(let projection) = result {
                cleanupMaterialization(projection, from: provider)
            }
            return
        }
        inFlight.abandonmentDeadlineTask?.cancel()
        releaseTrackedMaterialization(token)

        switch result {
        case .success(let projection):
            guard !inFlight.abandoned else {
                inFlightProjects[id] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                return
            }
            guard resources[id] != nil else {
                inFlightProjects[id] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                resume(inFlight.waiters, throwing: SurfaceCatalogError.unknownResource(id))
                return
            }
            let returnedProjection: SurfaceProjection
            let ownsProjection: Bool
            if let existing = projections.first(where: { $0.resource == id }) {
                if existing.panelID != projection.panelID {
                    cleanupMaterialization(projection, from: inFlight.provider)
                }
                returnedProjection = existing
                ownsProjection = false
            } else {
                record(projection)
                returnedProjection = projection
                ownsProjection = true
            }
            let waiters = inFlight.waiters
            inFlight.waiters.removeAll()
            inFlight.completedProjection = returnedProjection
            inFlight.completionOwnsProjection = ownsProjection
            inFlight.pendingAcknowledgements = Set(waiters.keys)
            inFlight.completionCleanupTask = completedMaterializationCleanupTask(id: id, token: token)
            inFlightProjects[id] = inFlight
            for waiter in waiters.values {
                waiter.continuation.resume(
                    returning: (projection: returnedProjection, reused: ownsProjection ? waiter.reused : true)
                )
            }
            if waiters.isEmpty {
                discardUnclaimedMaterializationIfEmpty(id)
            }
        case .failure(let error):
            inFlightProjects[id] = nil
            resume(inFlight.waiters, throwing: error)
        }
    }

    /// Finish the caller side of a successful materialization as one actor-isolated operation.
    /// The cancellation check and acknowledgement share the same turn, so cancellation cannot
    /// leave a newly recorded pane ownerless between those two actions.
    private func finalizeMaterializationWaiter(
        id: SurfaceResourceID,
        waiterID: UUID,
        result: SurfaceProjectionMaterialization.Result,
        focus: Bool
    ) throws -> SurfaceProjectionMaterialization.Result {
        guard !Task.isCancelled else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw CancellationError()
        }
        guard resources[id] != nil else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw SurfaceCatalogError.unknownResource(id)
        }
        guard projections.contains(result.projection) else {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            throw SurfaceCatalogError.unavailable(id, reason: "projection closed while opening")
        }
        acknowledgeMaterialization(id, waiterID: waiterID)
        if result.reused, focus { focusProjection?(result.projection) }
        return result
    }

    private func acknowledgeMaterialization(_ id: SurfaceResourceID, waiterID: UUID) {
        guard let inFlight = inFlightProjects[id], inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.contains(waiterID) else { return }
        // One accepted result gives the pane an owner. The other resumed callers no longer need
        // bookkeeping because their later cancellation must not close a pane this caller owns.
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[id] = nil
    }

    private func claimCompletedMaterializationIfNeeded(
        _ id: SurfaceResourceID,
        projection: SurfaceProjection
    ) throws {
        guard let inFlight = inFlightProjects[id],
              let completedProjection = inFlight.completedProjection,
              completedProjection.resource == projection.resource,
              completedProjection.panelID == projection.panelID else { return }
        guard !Task.isCancelled else { throw CancellationError() }
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[id] = nil
    }

    private func cancelCompletedMaterialization(_ id: SurfaceResourceID, waiterID: UUID) {
        guard var inFlight = inFlightProjects[id],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.remove(waiterID) != nil else { return }
        if inFlight.pendingAcknowledgements.isEmpty {
            inFlightProjects[id] = nil
            inFlight.completionCleanupTask?.cancel()
            if inFlight.completionOwnsProjection {
                cleanupRecordedMaterialization(inFlight)
            }
        } else {
            inFlightProjects[id] = inFlight
        }
    }

    /// Handles the defensive empty-set case without retaining a completed operation. Normal
    /// provider completions always have at least one waiter unless every caller cancelled first.
    private func discardUnclaimedMaterializationIfEmpty(_ id: SurfaceResourceID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[id] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func completedMaterializationCleanupTask(id: SurfaceResourceID, token: UUID) -> Task<Void, Never> {
        let timeout = completedMaterializationRetention
        let clock = materializationClock
        return Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireCompletedMaterialization(id, token: token)
        }
    }

    /// A caller can be dropped without cancellation, so completion bookkeeping needs a bounded
    /// recovery path. An acknowledged result is removed before this deadline; otherwise the
    /// operation is treated as unclaimed and any pane owned by it is discarded.
    private func expireCompletedMaterialization(_ id: SurfaceResourceID, token: UUID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.token == token,
              inFlight.completedProjection != nil,
              !inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[id] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func cleanupRecordedMaterialization(_ materialization: SurfaceProjectionMaterialization) {
        guard let projection = materialization.completedProjection else { return }
        let provider = materialization.provider
        let current = projections.first {
            $0.resource == projection.resource && $0.panelID == projection.panelID
        }
        let preserved = provider.discardMaterialization(current ?? projection)
        // A completed operation owns only the projection it recorded. If that projection was
        // removed before cleanup, a preserving provider must not resurrect the closed pane.
        guard let current, !preserved else { return }
        projections.remove(current)
        notifyChange()
    }

    /// Cleans up a provider result that arrived after its catalog operation was retired. A
    /// preserving provider moved an existing pane, so its late result must remain represented.
    private func cleanupMaterialization(_ projection: SurfaceProjection, from provider: any SurfaceProvider) {
        let preserved = provider.discardMaterialization(projection)
        guard preserved,
              providers[projection.resource.machine] === provider,
              resources[projection.resource] != nil,
              !projections.contains(where: {
                  $0.resource == projection.resource && $0.panelID == projection.panelID
              }) else { return }
        record(projection)
    }

    private func trackMaterialization(_ token: UUID, for provider: any SurfaceProvider) {
        trackedMaterializationTokens.insert(token)
        trackedMaterializationMachines[token] = provider.machine
        trackedMaterializationCounts[provider.machine, default: 0] += 1
    }

    private func releaseTrackedMaterialization(_ token: UUID) {
        guard trackedMaterializationTokens.remove(token) != nil,
              let machine = trackedMaterializationMachines.removeValue(forKey: token) else { return }
        let remaining = (trackedMaterializationCounts[machine] ?? 1) - 1
        if remaining > 0 {
            trackedMaterializationCounts[machine] = remaining
        } else {
            trackedMaterializationCounts[machine] = nil
        }
    }

    private func cancelInFlightProjectWaiter(_ id: SurfaceResourceID, waiterID: UUID) {
        guard let current = inFlightProjects[id] else { return }
        if current.completedProjection != nil {
            cancelCompletedMaterialization(id, waiterID: waiterID)
            return
        }
        var inFlight = current
        guard let waiter = inFlight.waiters.removeValue(forKey: waiterID) else { return }
        if inFlight.waiters.isEmpty {
            // Cancellation detaches this caller, but the provider operation stays single-flight
            // until it settles. Provider cancellation is cooperative, so starting another call
            // here would allow an unbounded number of remote panes to race the first one. The
            // abandonment deadline below is the recovery boundary for a provider that never
            // observes cancellation.
            inFlight.abandoned = true
            let token = inFlight.token
            let timeout = abandonedMaterializationTimeout
            let clock = materializationClock
            inFlight.abandonmentDeadlineTask = Task { @MainActor [weak self, clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.expireAbandonedMaterialization(id, token: token)
            }
        }
        inFlightProjects[id] = inFlight
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Retire a detached provider operation after its bounded recovery window. New callers can
    /// start a fresh operation immediately while the old task drains cooperatively.
    private func expireAbandonedMaterialization(_ id: SurfaceResourceID, token: UUID) {
        guard let inFlight = inFlightProjects[id],
              inFlight.token == token,
              inFlight.completedProjection == nil,
              inFlight.abandoned,
              inFlight.waiters.isEmpty else { return }
        inFlightProjects[id] = nil
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(token)
        inFlight.task.cancel()
    }

    /// Keep only a short-lived token for a retired operation. A late success is always stale,
    /// so `finishInFlightProject` can discard it directly with the provider captured by its task
    /// even after this token has been evicted.
    private func retireMaterialization(_ token: UUID) {
        precondition(trackedMaterializationTokens.contains(token))
        retiredMaterializationTokens.insert(token)
        let timeout = retiredMaterializationRetention
        let clock = materializationClock
        let evictionTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.evictRetiredMaterialization(token)
        }
        guard retiredMaterializationTokens.contains(token) else {
            evictionTask.cancel()
            return
        }
        retiredMaterializationEvictionTasks[token] = evictionTask
    }

    private func evictRetiredMaterialization(_ token: UUID) {
        guard retiredMaterializationTokens.remove(token) != nil else { return }
        retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
        // The provider may ignore cancellation and never report a result. Once the bounded
        // retirement window ends, stop counting that operation against its machine. A later
        // completion releases the token idempotently and still receives stale-result cleanup.
        releaseTrackedMaterialization(token)
    }

    private func cancelInFlightProject(_ id: SurfaceResourceID, error: any Error) {
        guard let current = inFlightProjects[id], current.completedProjection == nil,
              let inFlight = inFlightProjects.removeValue(forKey: id) else { return }
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(inFlight.token)
        inFlight.task.cancel()
        let waiters = inFlight.waiters
        resume(waiters, throwing: error)
    }

    private func resume(
        _ waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<SurfaceProjectionMaterialization.Result, Error>)],
        throwing error: any Error
    ) {
        for waiter in waiters.values {
            waiter.continuation.resume(throwing: error)
        }
    }

    /// Record a pane that shows a resource (materialized by a provider, or adopted from an
    /// existing pane such as a local terminal the app created on its own).
    func record(_ projection: SurfaceProjection) {
        insertSupersedingLocalPlaceholder(projection)
        if !projection.resource.machine.isLocal {
            CloudWorkspaceRenameWriteThrough.reconcileBinding(
                localWorkspaceID: projection.workspaceID,
                catalog: self
            )
        }
        notifyChange()
    }

    /// A pane can show one resource. When a remote resource is projected into a pane the
    /// local provider already registered as a plain local terminal (the pane is created
    /// first, then attached), the local placeholder yields: its projection ends and the
    /// local resource disappears, so the pane counts once, as the remote terminal.
    private func insertSupersedingLocalPlaceholder(_ projection: SurfaceProjection) {
        if !projection.resource.machine.isLocal {
            for existing in projections where existing.panelID == projection.panelID && existing.resource.machine.isLocal {
                projections.remove(existing)
                resources[existing.resource] = nil
                resourceIDsByMachine[existing.resource.machine]?.remove(existing.resource)
                if resourceIDsByMachine[existing.resource.machine]?.isEmpty == true {
                    resourceIDsByMachine[existing.resource.machine] = nil
                }
            }
        }
        projections.insert(projection)
    }

    /// A pane went away (closed, or its workspace closed). Remote resources live on.
    func endProjections(panelID: UUID) {
        let ended = projections.filter { $0.panelID == panelID }
        guard !ended.isEmpty else { return }
        projections.subtract(ended)
        for projection in ended {
            providers[projection.resource.machine]?.projectionDidEnd(projection)
        }
        notifyChange()
    }

    /// A pane moved to another workspace (tab transfer / drag between windows).
    func moveProjections(panelID: UUID, to workspaceID: UUID) {
        let moved = projections.filter { $0.panelID == panelID }
        guard !moved.isEmpty else { return }
        projections.subtract(moved)
        for var projection in moved {
            projection.workspaceID = workspaceID
            projections.insert(projection)
        }
        CloudWorkspaceRenameWriteThrough.reconcileBinding(localWorkspaceID: workspaceID, catalog: self)
        notifyChange()
    }

    func projections(of id: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == id }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }

    func resource(forPanel panelID: UUID) -> SurfaceResource? {
        projection(forPanel: panelID).flatMap { resources[$0.resource] }
    }

    // MARK: Restore

    /// Records persisted projections for panes the session restore recreated. The projection
    /// becomes live as soon as the provider reports the resource again (a cloud terminal
    /// after the link reconnects); local resources are re-registered by the local provider
    /// with the same panel-derived key, so they resolve immediately.
    func restore(_ records: [SurfaceProjectionRecord], workspaceID: UUID) {
        for record in records {
            if resources[record.resource] != nil {
                insertSupersedingLocalPlaceholder(SurfaceProjection(resource: record.resource, workspaceID: workspaceID, panelID: record.panelID))
            } else {
                pendingRestoredProjections[record] = workspaceID
            }
        }
        for record in records where !record.resource.machine.isLocal {
            CloudWorkspaceRenameWriteThrough.reconcileBinding(
                localWorkspaceID: workspaceID,
                catalog: self
            )
        }
        notifyChange()
    }

    func projectionRecords(forWorkspace workspaceID: UUID) -> [SurfaceProjectionRecord] {
        projections
            .filter { $0.workspaceID == workspaceID }
            .map { SurfaceProjectionRecord(panelID: $0.panelID, resource: $0.resource) }
            .sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    /// Cloud machine IDs referenced by restored panes that are waiting for a
    /// provider to report their resources. The registry uses these IDs during
    /// stale-machine reconciliation so a deleted ID cannot attach old panes
    /// when a different machine later receives the same ID.
    var pendingRestoredMachineIDs: Set<String> {
        Set(pendingRestoredProjections.keys.compactMap { $0.resource.machine.cloudMachineID })
    }

    /// Returns whether at least one resource is currently published for a machine.
    /// This is intentionally unsorted and does not materialize a snapshot.
    func hasResources(on machine: SurfaceMachineID) -> Bool {
        !(resourceIDsByMachine[machine]?.isEmpty ?? true)
    }

    private func resolvePendingRestoredProjections(on machine: SurfaceMachineID) {
        for (record, workspaceID) in pendingRestoredProjections where record.resource.machine == machine {
            guard resources[record.resource] != nil else { continue }
            insertSupersedingLocalPlaceholder(SurfaceProjection(resource: record.resource, workspaceID: workspaceID, panelID: record.panelID))
            if !record.resource.machine.isLocal {
                CloudWorkspaceRenameWriteThrough.reconcileBinding(
                    localWorkspaceID: workspaceID,
                    catalog: self
                )
            }
            pendingRestoredProjections[record] = nil
        }
    }

    // MARK: Snapshot

    var snapshot: SurfaceCatalogSnapshot {
        let orderedMachines = machines.values.sorted { lhs, rhs in
            if lhs.id.isLocal != rhs.id.isLocal { return lhs.id.isLocal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let orderedResources = resources.values.sorted { lhs, rhs in
            if lhs.machine != rhs.machine { return lhs.machine.rawValue < rhs.machine.rawValue }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            let li = lhs.remoteWorkspace?.index ?? -1, ri = rhs.remoteWorkspace?.index ?? -1
            if li != ri { return li < ri }
            return lhs.id.key < rhs.id.key
        }
        return SurfaceCatalogSnapshot(
            machines: orderedMachines,
            resources: orderedResources,
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        )
    }

    /// Observers get at most one notification per main-runloop turn: a burst of upserts
    /// (a busy shell retitling, a snapshot replacing dozens of resources) collapses into
    /// one hop, so the sidebar rebuilds once instead of once per mutation.
    private var changeNotificationPending = false

    private func notifyChange() {
        guard !changeNotificationPending else { return }
        changeNotificationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.changeNotificationPending = false
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
