import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The P3 red/green guard: two Macs reporting the SAME bare workspace/terminal
/// id strings must route selection, terminal input, and render-grid byte
/// delivery to the correct Mac. The structural fix is the Mac-scoped surface
/// key (`"<deviceId>#<terminalID>"`); these tests prove a colliding bare id on a
/// non-active Mac can never steal the active Mac's surface, and that the
/// single-Mac (unscoped) case still resolves.
@MainActor
@Suite struct ScopedSurfaceRoutingTests {
    private func terminal(_ id: String, deviceId: String) -> MobileTerminalPreview {
        MobileTerminalPreview(id: .init(rawValue: id), deviceId: deviceId, name: "T")
    }

    private func workspace(
        id: String,
        deviceId: String,
        terminalID: String
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            deviceId: deviceId,
            name: "WS \(id)",
            terminals: [terminal(terminalID, deviceId: deviceId)]
        )
    }

    /// Mount an output sink for a scoped surface key and collect what it
    /// receives, mirroring how the terminal surface attaches in production.
    private func mountSink(
        _ store: MobileShellComposite,
        surfaceKey: String,
        into bag: ChunkBag
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await chunk in store.terminalOutputStream(surfaceID: surfaceKey) {
                bag.append(chunk.data)
                store.terminalOutputDidProcess(surfaceID: surfaceKey, streamToken: chunk.streamToken)
            }
        }
    }

    @MainActor
    final class ChunkBag {
        private(set) var count = 0
        func append(_ data: Data) { count += data.isEmpty ? 0 : 1 }
    }

    // MARK: - Render-grid byte delivery routing

    @Test func renderGridBytesRouteOnlyToActiveMacSurface() async throws {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        // Both Macs use the SAME bare terminal id "term-1".
        store.debugSetActiveDeviceID("mac-A")

        let keyA = ScopedTerminalID(deviceId: "mac-A", terminalID: .init(rawValue: "term-1")).surfaceKey
        let keyB = ScopedTerminalID(deviceId: "mac-B", terminalID: .init(rawValue: "term-1")).surfaceKey
        #expect(keyA != keyB, "colliding bare ids must produce distinct scoped keys")

        let bagA = ChunkBag()
        let bagB = ChunkBag()
        let taskA = mountSink(store, surfaceKey: keyA, into: bagA)
        let taskB = mountSink(store, surfaceKey: keyB, into: bagB)
        defer { taskA.cancel(); taskB.cancel() }

        // Let both sinks register.
        _ = try await pollUntil { store.debugRegisteredSurfaceKeys.isSuperset(of: [keyA, keyB]) }

        // A render-grid event from the active Mac echoes the BARE wire id "term-1".
        store.debugDeliverActiveMacRenderGrid(wireSurfaceID: "term-1", seq: 42, text: "hello")

        // Only the active Mac's scoped surface recorded the frame; the colliding
        // non-active surface saw nothing.
        #expect(store.debugDeliveredEndSeq(forSurfaceKey: keyA) == 42)
        #expect(store.debugDeliveredEndSeq(forSurfaceKey: keyB) == nil)

        _ = try await pollUntil { bagA.count >= 1 }
        #expect(bagA.count >= 1)
        #expect(bagB.count == 0)
    }

    // MARK: - Input / wire routing

    @Test func wireTerminalResolvesOnlyForActiveMacKey() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [workspace(id: "ws-1", deviceId: "mac-A", terminalID: "term-1")]
        store.debugSetActiveDeviceID("mac-A")

        let keyActive = ScopedTerminalID(deviceId: "mac-A", terminalID: .init(rawValue: "term-1")).surfaceKey
        let keyOther = ScopedTerminalID(deviceId: "mac-B", terminalID: .init(rawValue: "term-1")).surfaceKey

        // The active Mac's key resolves to the bare wire id and the active
        // workspace; the colliding non-active Mac's key resolves to neither, so
        // input/scroll/viewport against it is a safe no-op instead of routing to
        // the wrong Mac.
        #expect(store.wireTerminalID(forSurfaceKey: keyActive) == "term-1")
        #expect(store.workspaceID(forTerminalID: keyActive)?.rawValue == "ws-1")
        #expect(store.wireTerminalID(forSurfaceKey: keyOther) == nil)
        #expect(store.workspaceID(forTerminalID: keyOther) == nil)
    }

    @Test func collidingBareIdInputLandsOnActiveMacOnly() async {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [workspace(id: "ws-1", deviceId: "mac-A", terminalID: "term-1")]
        store.debugSetActiveDeviceID("mac-A")

        let keyOther = ScopedTerminalID(deviceId: "mac-B", terminalID: .init(rawValue: "term-1")).surfaceKey
        // Submitting input for the OTHER Mac's surface (same bare id) must not
        // resolve a workspace on the active client. With no transport it cannot
        // assert the wire, but the routing guard (wireTerminalID == nil) is the
        // hard invariant proved above; here we additionally confirm the input
        // path early-outs without crashing for the wrong-Mac key.
        await store.submitTerminalRawInput(Data("x".utf8), surfaceID: keyOther)
        #expect(store.wireTerminalID(forSurfaceKey: keyOther) == nil)
    }

    // MARK: - Single-Mac (unscoped) parity

    @Test func unscopedKeyResolvesForSingleMac() async throws {
        // No active device id (manual ticket / single-Mac): the key is unscoped
        // ("#term-1") and must still resolve to the wire id and the workspace,
        // and render-grid bytes must still land.
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [workspace(id: "ws-1", deviceId: "", terminalID: "term-1")]

        let key = ScopedTerminalID(deviceId: "", terminalID: .init(rawValue: "term-1")).surfaceKey
        #expect(store.wireTerminalID(forSurfaceKey: key) == "term-1")
        #expect(store.workspaceID(forTerminalID: key)?.rawValue == "ws-1")

        let bag = ChunkBag()
        let task = mountSink(store, surfaceKey: key, into: bag)
        defer { task.cancel() }
        _ = try await pollUntil { store.debugRegisteredSurfaceKeys.contains(key) }

        store.debugDeliverActiveMacRenderGrid(wireSurfaceID: "term-1", seq: 7, text: "ok")
        #expect(store.debugDeliveredEndSeq(forSurfaceKey: key) == 7)
    }

    // MARK: - Lazy heavy-attach selection

    @Test func selectingActiveMacScopeLandsSelectionWithoutActivation() async {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [workspace(id: "ws-1", deviceId: "mac-A", terminalID: "term-1")]
        store.debugSetActiveDeviceID("mac-A")

        await store.selectScopedWorkspace(
            ScopedWorkspaceID(deviceId: "mac-A", workspaceID: "ws-1")
        )
        // Same Mac: the bare selection lands and no activation ran.
        #expect(store.selectedWorkspaceID == "ws-1")
        #expect(store.activatingDeviceID == nil)
    }

    @Test func selectingUnreachableOtherMacDoesNotChangeSelection() async {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = [workspace(id: "ws-1", deviceId: "mac-A", terminalID: "term-1")]
        store.debugSetActiveDeviceID("mac-A")
        store.selectedWorkspaceID = "ws-1"

        // mac-B is not in the registry/paired tree, so activateMac cannot resolve
        // a route: the heavy connection stays on mac-A and the selection is NOT
        // moved to a workspace id that does not exist on the active client.
        await store.selectScopedWorkspace(
            ScopedWorkspaceID(deviceId: "mac-B", workspaceID: "ws-9")
        )
        #expect(store.activeDeviceID == "mac-A")
        #expect(store.selectedWorkspaceID == "ws-1")
        #expect(store.activatingDeviceID == nil)
    }

    // MARK: - Flag-off parity

    @Test func flagOffUsesUnscopedSurfaceRouting() {
        // Flag off: the active Mac is still tagged (its real device id), but the
        // surface key the UI builds for a flag-off single-Mac is unscoped because
        // the workspace's deviceId is "" until the unified merge tags it. The
        // wire resolution must remain bare-id identical to today.
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: false)
        store.workspaces = [workspace(id: "ws-1", deviceId: "", terminalID: "term-1")]

        let key = ScopedTerminalID(deviceId: "", terminalID: .init(rawValue: "term-1")).surfaceKey
        #expect(store.wireTerminalID(forSurfaceKey: key) == "term-1")
        #expect(store.workspaceID(forTerminalID: key)?.rawValue == "ws-1")
    }
}
