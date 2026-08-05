import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlHandleRegistry")
struct ControlHandleRegistryTests {
    @Test func mintsSequentialRefsPerKind() {
        let registry = ControlHandleRegistry()
        let a = UUID()
        let b = UUID()
        #expect(registry.ensureRef(kind: .workspace, uuid: a) == "workspace:1")
        #expect(registry.ensureRef(kind: .workspace, uuid: b) == "workspace:2")
        // Independent ordinal space per kind.
        #expect(registry.ensureRef(kind: .surface, uuid: a) == "surface:1")
        #expect(registry.ensureRef(kind: .window, uuid: b) == "window:1")
    }

    @Test func ensureRefIsIdempotentPerIdentity() {
        let registry = ControlHandleRegistry()
        let id = UUID()
        let first = registry.ensureRef(kind: .pane, uuid: id)
        #expect(registry.ensureRef(kind: .pane, uuid: id) == first)
        #expect(registry.ensureRef(kind: .pane, uuid: UUID()) == "pane:2")
    }

    @Test func workspaceGroupRefsUseTheWireRawValue() {
        let registry = ControlHandleRegistry()
        #expect(registry.ensureRef(kind: .workspaceGroup, uuid: UUID()) == "workspace_group:1")
    }

    @Test func resolvesMintedRefsBack() {
        let registry = ControlHandleRegistry()
        let id = UUID()
        let ref = registry.ensureRef(kind: .surface, uuid: id)
        #expect(registry.uuid(forRef: ref) == id)
        #expect(registry.uuid(forRef: "surface:99") == nil)
        #expect(registry.uuid(forRef: "bogus") == nil)
    }

    @Test func removeRefForgetsBothDirectionsWithoutReusingOrdinals() {
        let registry = ControlHandleRegistry()
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
        let registry = ControlHandleRegistry()
        let id = UUID()
        _ = registry.ensureRef(kind: .surface, uuid: id)
        #expect(registry.uuid(forRef: "tab:1") == id)
        #expect(registry.uuid(forRef: "  TAB:1  ") == id)
        #expect(registry.uuid(forRef: "tab:2") == nil)
        #expect(registry.uuid(forRef: "tab:x") == nil)
    }

    // A single identity, minted concurrently from many threads, must resolve to
    // exactly one ref. Without synchronization the check-then-mint in
    // `ensureRef` races: several threads miss the existing entry and each mint a
    // fresh ordinal, so the identity ends up with multiple refs.
    @Test func concurrentEnsureRefForSameIdentityMintsExactlyOneRef() {
        let registry = ControlHandleRegistry()
        let id = UUID()
        let seenLock = NSLock()
        var seen = Set<String>()

        DispatchQueue.concurrentPerform(iterations: 4_000) { _ in
            let ref = registry.ensureRef(kind: .surface, uuid: id)
            seenLock.lock()
            seen.insert(ref)
            seenLock.unlock()
        }

        #expect(seen == ["surface:1"])
    }

    // Distinct identities minted concurrently must each keep a unique,
    // round-tripping ref. Without synchronization concurrent mutation corrupts
    // the backing dictionaries — lost inserts, colliding ordinals, or a crash.
    @Test func concurrentEnsureRefForDistinctIdentitiesStaysConsistent() {
        let registry = ControlHandleRegistry()
        let count = 2_000
        let ids = (0..<count).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            _ = registry.ensureRef(kind: .surface, uuid: ids[i])
        }

        var refs = Set<String>()
        for id in ids {
            let ref = registry.ensureRef(kind: .surface, uuid: id)
            refs.insert(ref)
            #expect(registry.uuid(forRef: ref) == id)
        }
        // One distinct ref per distinct identity: no lost or colliding inserts.
        #expect(refs.count == count)
    }
}
