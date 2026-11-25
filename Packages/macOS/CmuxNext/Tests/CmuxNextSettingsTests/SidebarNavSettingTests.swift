import CmuxNextSettings
import Testing

/// `sidebar.nav`: a look's nav block at the top of the sidebar, a list of cmux action ids (each
/// optionally "id | Title | symbol"). Rust validates it; empty by default, which draws no block.
struct SidebarNavSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["nav": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func emptyByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.nav.isEmpty)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func rowsCarryTheirActionAndTheLooksOverrides() {
        let snapshot = Self.parse(.array([.string("palette.newAgentChat | New chat | square.and.pencil"), .string("search.chats")]))
        #expect(snapshot.sidebarSections.nav.map(\.action) == ["palette.newAgentChat", "search.chats"])
        #expect(snapshot.sidebarSections.nav.first?.title == "New chat")
        #expect(snapshot.sidebarSections.nav.first?.symbol == "square.and.pencil")
        #expect(snapshot.sidebarSections.nav.last?.title == nil)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func anUnknownActionIsDroppedWithADiagnosticAndTheRestDraw() {
        let snapshot = Self.parse(.array([.string("no.such.action"), .string("home.show")]))
        #expect(snapshot.sidebarSections.nav.map(\.action) == ["home.show"])
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.nav[0]" }, "\(snapshot.diagnostics)")
    }

    @Test func anAgentMaySetItAndTheDefaultIsEmpty() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "nav"]))
        #expect(descriptor.defaultValue == .array([]))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.nav"))
    }
}
