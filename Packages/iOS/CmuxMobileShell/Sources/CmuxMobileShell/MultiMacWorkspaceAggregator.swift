public import CMUXMobileCore
public import CmuxMobileRPC
public import CmuxMobileShellModel
public import Foundation
import Observation
internal import OSLog

private let aggregatorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "multi-mac-aggregator"
)

/// Fetches the workspace lists of the user's *other* online Macs and exposes
/// them as per-device slices for the unified multi-Mac list.
///
/// The phone keeps one "heavy" connection (render-grid stream, liveness
/// watchdog, terminal byte streams) to the Mac whose terminal is on screen —
/// that lives in ``MobileShellComposite``. This aggregator is the lightweight
/// counterpart: for every *other* online Mac it opens a short-lived
/// ``MobileCoreRPCClient`` (built by
/// ``MobileShellComposite/makeMacListClient(runtime:deviceId:displayName:route:)``),
/// pulls `mobile.workspace.list` once, tags the returned previews with the
/// owning Mac's `deviceId`, and lets the client idle. It owns NO render
/// streams, watchdogs, or terminal input; it is read-only workspace metadata.
///
/// Failure isolation is a hard requirement: one Mac being unreachable records
/// an error for *that* device only and must never blank another device's
/// already-fetched slice. Per-device refreshes coalesce so overlapping calls
/// (a presence event landing while a pull-to-refresh is in flight) reuse the
/// single in-flight fetch instead of stacking duplicate RPCs.
@MainActor
@Observable
public final class MultiMacWorkspaceAggregator {
    /// One online Mac the aggregator should fetch from. The active (heavy)
    /// Mac is intentionally excluded by the caller, so every target here gets a
    /// short-lived list client.
    public struct Target: Sendable, Equatable {
        /// The Mac's cmux device UUID, stamped onto every fetched preview.
        public var deviceId: String
        /// A human label for the synthetic list-client ticket.
        public var displayName: String
        /// The attach route to dial for the one-shot workspace-list fetch.
        public var route: CmxAttachRoute

        public init(deviceId: String, displayName: String, route: CmxAttachRoute) {
            self.deviceId = deviceId
            self.displayName = displayName
            self.route = route
        }
    }

    /// The latest workspace slice fetched per device, keyed by `deviceId`.
    /// Every preview in a slice is tagged with that device's id. A device with
    /// an in-flight first fetch simply has no entry yet.
    public private(set) var perDeviceWorkspaces: [String: [MobileWorkspacePreview]] = [:]

    /// The latest fetch error per device, keyed by `deviceId`. Set when a
    /// device's fetch fails and cleared on its next success. Isolated per
    /// device so one Mac's failure never affects another's slice.
    public private(set) var perDeviceError: [String: any Error] = [:]

    private let runtime: (any MobileSyncRuntime)?
    /// In-flight fetch task per device, so overlapping refreshes coalesce onto
    /// one RPC rather than stacking duplicates.
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// - Parameter runtime: The DI runtime. `nil` in previews/tests with no
    ///   transport, where every refresh is a no-op.
    public init(runtime: (any MobileSyncRuntime)?) {
        self.runtime = runtime
    }

    /// Refresh every target's slice, coalescing per-device, and prune slices
    /// for devices no longer in `targets` (a Mac that went offline or is now
    /// the active heavy connection).
    ///
    /// Returns after every per-device fetch this call started (or joined) has
    /// settled, so a pull-to-refresh can await real completion.
    /// - Parameter targets: The online, non-active Macs to fetch from.
    public func refresh(targets: [Target]) async {
        let liveDeviceIDs = Set(targets.map(\.deviceId))
        pruneDevices(absentFrom: liveDeviceIDs)

        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                let task = refreshTask(for: target)
                group.addTask { await task.value }
            }
            await group.waitForAll()
        }
    }

    /// Drop all per-device state and cancel in-flight fetches (sign-out, or the
    /// flag turning off). Leaves the aggregator inert until the next refresh.
    public func reset() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight = [:]
        perDeviceWorkspaces = [:]
        perDeviceError = [:]
    }

    /// Workspaces fetched for one device, already tagged with its id. Empty
    /// when the device has no slice yet (first fetch in flight, or it failed
    /// before ever succeeding).
    public func workspaces(forDeviceID deviceID: String) -> [MobileWorkspacePreview] {
        perDeviceWorkspaces[deviceID] ?? []
    }

    // MARK: - Internals

    /// Remove slices and errors for devices not in `liveDeviceIDs`, and cancel
    /// any of their in-flight fetches. A device drops out when it goes offline
    /// or becomes the active heavy connection (the composite stops listing it
    /// as a target).
    private func pruneDevices(absentFrom liveDeviceIDs: Set<String>) {
        for deviceID in perDeviceWorkspaces.keys where !liveDeviceIDs.contains(deviceID) {
            perDeviceWorkspaces.removeValue(forKey: deviceID)
        }
        for deviceID in perDeviceError.keys where !liveDeviceIDs.contains(deviceID) {
            perDeviceError.removeValue(forKey: deviceID)
        }
        for deviceID in inFlight.keys where !liveDeviceIDs.contains(deviceID) {
            inFlight[deviceID]?.cancel()
            inFlight.removeValue(forKey: deviceID)
        }
    }

    /// The coalesced fetch task for a target: reuse the in-flight one when a
    /// fetch for this device is already running, otherwise start one.
    private func refreshTask(for target: Target) -> Task<Void, Never> {
        if let existing = inFlight[target.deviceId] {
            return existing
        }
        let task = Task { @MainActor [weak self] in
            await self?.performFetch(target)
            self?.inFlight.removeValue(forKey: target.deviceId)
        }
        inFlight[target.deviceId] = task
        return task
    }

    /// Fetch one device's `mobile.workspace.list` over a short-lived client and
    /// store the tagged slice, or record the error. Never throws and never
    /// touches another device's state.
    private func performFetch(_ target: Target) async {
        guard let runtime else { return }
        guard let client = MobileShellComposite.makeMacListClient(
            runtime: runtime,
            deviceId: target.deviceId,
            displayName: target.displayName,
            route: target.route
        ) else {
            // No dialable Stack-auth route: a no-op that leaves any prior slice
            // intact rather than blanking it.
            aggregatorLog.debug(
                "no list-client route device=\(target.deviceId, privacy: .public)"
            )
            return
        }
        defer { Task { await client.disconnect() } }

        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.workspace.list",
                params: [:]
            )
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            if Task.isCancelled { return }
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            let tagged = response.workspaces.map { remote in
                var workspace = MobileWorkspacePreview(remote: remote)
                workspace.deviceId = target.deviceId
                workspace.terminals = workspace.terminals.map { terminal in
                    var terminal = terminal
                    terminal.deviceId = target.deviceId
                    return terminal
                }
                return workspace
            }
            perDeviceWorkspaces[target.deviceId] = tagged
            perDeviceError.removeValue(forKey: target.deviceId)
        } catch {
            if Task.isCancelled { return }
            // Isolate the failure to this device. A previously-fetched slice is
            // left untouched so a transient blip does not blank a working Mac.
            perDeviceError[target.deviceId] = error
            aggregatorLog.error(
                "workspace.list fetch failed device=\(target.deviceId, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }
}

#if DEBUG
extension MultiMacWorkspaceAggregator {
    /// Test-only seam to seed a per-device slice (already tagged by the caller)
    /// without a live fetch, so the composite's merge/gating can be tested in
    /// isolation from the transport.
    public func debugSetSlice(deviceID: String, workspaces: [MobileWorkspacePreview]) {
        perDeviceWorkspaces[deviceID] = workspaces
    }
}
#endif
