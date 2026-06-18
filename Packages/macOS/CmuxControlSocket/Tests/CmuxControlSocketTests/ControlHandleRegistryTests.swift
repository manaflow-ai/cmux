import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlHandleRegistry")
struct ControlHandleRegistryTests {
    @Test func mintsSequentialRefsPerKind() {
        var registry = ControlHandleRegistry()
        let a = UUID()
        let b = UUID()
        #expect(registry.ensureRef(kind: .workspace, uuid: a) == "workspace:1")
        #expect(registry.ensureRef(kind: .workspace, uuid: b) == "workspace:2")
        // Independent ordinal space per kind.
        #expect(registry.ensureRef(kind: .surface, uuid: a) == "surface:1")
        #expect(registry.ensureRef(kind: .window, uuid: b) == "window:1")
    }

    @Test func ensureRefIsIdempotentPerIdentity() {
        var registry = ControlHandleRegistry()
        let id = UUID()
        let first = registry.ensureRef(kind: .pane, uuid: id)
        #expect(registry.ensureRef(kind: .pane, uuid: id) == first)
        #expect(registry.ensureRef(kind: .pane, uuid: UUID()) == "pane:2")
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
}
