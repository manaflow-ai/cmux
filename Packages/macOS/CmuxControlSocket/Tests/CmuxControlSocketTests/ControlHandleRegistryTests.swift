import Foundation
import Testing
@testable import CmuxControlSocket

private final class ControlHandleOrdinalAdvanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(ControlHandleKind, Int)] = []

    func record(kind: ControlHandleKind, nextOrdinal: Int) {
        lock.lock()
        values.append((kind, nextOrdinal))
        lock.unlock()
    }

    func snapshot() -> [(ControlHandleKind, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("ControlHandleRegistry")
struct ControlHandleRegistryTests {
    /// Fixed, distinct identities so assertions that depend on two UUIDs
    /// differing can never flake on a random collision.
    private func fixedUUID(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    @Test func mintsSequentialRefsPerKind() {
        var registry = ControlHandleRegistry()
        let a = fixedUUID(1)
        let b = fixedUUID(2)
        #expect(registry.ensureRef(kind: .workspace, uuid: a) == "workspace:1")
        #expect(registry.ensureRef(kind: .workspace, uuid: b) == "workspace:2")
        // Independent ordinal space per kind.
        #expect(registry.ensureRef(kind: .surface, uuid: a) == "surface:1")
        #expect(registry.ensureRef(kind: .window, uuid: b) == "window:1")
    }

    @Test func customStartingOrdinalsKeepOldRefsUnknown() {
        let oldID = UUID()
        var oldRegistry = ControlHandleRegistry()
        let oldRef = oldRegistry.ensureRef(kind: .surface, uuid: oldID)
        #expect(oldRef == "surface:1")

        let newID = UUID()
        var newRegistry = ControlHandleRegistry(startingOrdinals: [.surface: 1_000_000_000])
        let newRef = newRegistry.ensureRef(kind: .surface, uuid: newID)

        #expect(newRef == "surface:1000000000")
        #expect(newRegistry.uuid(forRef: oldRef) == nil)
        #expect(newRegistry.uuid(forRef: newRef) == newID)
    }

    @Test func ordinalAdvanceHookRunsOnlyForNewRefs() {
        let recorder = ControlHandleOrdinalAdvanceRecorder()
        var registry = ControlHandleRegistry(
            startingOrdinals: [.surface: 40]
        ) { kind, nextOrdinal in
            recorder.record(kind: kind, nextOrdinal: nextOrdinal)
        }
        let id = UUID()

        #expect(registry.ensureRef(kind: .surface, uuid: id) == "surface:40")
        #expect(registry.ensureRef(kind: .surface, uuid: id) == "surface:40")
        #expect(registry.ensureRef(kind: .surface, uuid: UUID()) == "surface:41")

        let advances = recorder.snapshot()
        #expect(advances.count == 2)
        #expect(advances[0].0 == .surface)
        #expect(advances[0].1 == 41)
        #expect(advances[1].0 == .surface)
        #expect(advances[1].1 == 42)
    }

    @Test func ensureRefIsIdempotentPerIdentity() {
        var registry = ControlHandleRegistry()
        let id = fixedUUID(1)
        let first = registry.ensureRef(kind: .pane, uuid: id)
        #expect(registry.ensureRef(kind: .pane, uuid: id) == first)
        #expect(registry.ensureRef(kind: .pane, uuid: fixedUUID(2)) == "pane:2")
    }

    @Test func existingRefPeeksWithoutMinting() {
        var registry = ControlHandleRegistry()
        let a = fixedUUID(1)
        let b = fixedUUID(2)
        // Peeking never mints, so an unseen identity has no ref...
        #expect(registry.existingRef(kind: .workspace, uuid: a) == nil)
        // ...and peeking did not consume the first ordinal.
        #expect(registry.ensureRef(kind: .workspace, uuid: a) == "workspace:1")
        // Once minted, the peek returns the same ref.
        #expect(registry.existingRef(kind: .workspace, uuid: a) == "workspace:1")
        // A peek for a still-unseen identity stays nil and leaves ordinals intact.
        #expect(registry.existingRef(kind: .workspace, uuid: b) == nil)
        #expect(registry.ensureRef(kind: .workspace, uuid: b) == "workspace:2")
    }

    @Test func workspaceGroupRefsUseTheWireRawValue() {
        var registry = ControlHandleRegistry()
        #expect(registry.ensureRef(kind: .workspaceGroup, uuid: UUID()) == "workspace_group:1")
    }

    @Test func resolvesMintedRefsBack() {
        var registry = ControlHandleRegistry()
        let id = UUID()
        let ref = registry.ensureRef(kind: .surface, uuid: id)
        #expect(registry.uuid(forRef: ref) == id)
        #expect(registry.uuid(forRef: "surface:99") == nil)
        #expect(registry.uuid(forRef: "bogus") == nil)
    }

    @Test func removeRefForgetsBothDirectionsWithoutReusingOrdinals() {
        var registry = ControlHandleRegistry()
        let id = UUID()
        let ref = registry.ensureRef(kind: .surface, uuid: id)
        registry.removeRef(kind: .surface, uuid: id)
        #expect(registry.uuid(forRef: ref) == nil)
        // Re-registering mints a fresh ref; ordinals are never reused.
        #expect(registry.ensureRef(kind: .surface, uuid: id) == "surface:2")
        // Removing an unknown identity is a no-op.
        registry.removeRef(kind: .surface, uuid: UUID())
    }

    @Test func tabRefsAliasSurfaceRefs() {
        var registry = ControlHandleRegistry()
        let id = UUID()
        _ = registry.ensureRef(kind: .surface, uuid: id)
        #expect(registry.uuid(forRef: "tab:1") == id)
        #expect(registry.uuid(forRef: "  TAB:1  ") == id)
        #expect(registry.uuid(forRef: "tab:2") == nil)
        #expect(registry.uuid(forRef: "tab:x") == nil)
    }

    @Test func topologyRefreshClaimCoalescesWithinOneSnapshotGeneration() {
        var registry = ControlHandleRegistry()
        #expect(registry.needsTopologyRefresh)
        registry.markTopologyRefreshCompleted()
        #expect(!registry.needsTopologyRefresh)
        _ = registry.ensureRef(kind: .surface, uuid: UUID())
        #expect(!registry.needsTopologyRefresh)
        registry.markTopologyRefreshCompleted()
        registry.invalidateTopologyRefresh()
        #expect(registry.needsTopologyRefresh)
    }
}
