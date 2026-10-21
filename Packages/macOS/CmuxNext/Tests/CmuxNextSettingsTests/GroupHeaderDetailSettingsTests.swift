import CmuxNextSettings
import Testing

/// `sidebar.groupHeader.memberCount` and `sidebar.groupHeader.unreadCount` (Lawrence 2026-10-20:
/// "Group settings don't show too much detail by default. All we care about is the loading."):
/// a group header shows no counts by default; the user turns each on in Settings, cmux.json,
/// `cmux settings set` or Cmd+Shift+P.
struct GroupHeaderDetailSettingsTests {
    static func parse(_ values: [String: JSONValue]) -> CmuxConfigSnapshot {
        let root: JSONValue = .object(["sidebar": .object(["groupHeader": .object(values)])])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.sidebarSections.groupHeaderMemberCount == false)
        #expect(snapshot.sidebarSections.groupHeaderUnreadCount == false)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnThemOn() {
        let snapshot = Self.parse(["memberCount": .bool(true), "unreadCount": .bool(true)])
        #expect(snapshot.sidebarSections.groupHeaderMemberCount)
        #expect(snapshot.sidebarSections.groupHeaderUnreadCount)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["memberCount": .string("on")])
        #expect(snapshot.sidebarSections.groupHeaderMemberCount == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.groupHeader.memberCount" }, "\(snapshot.diagnostics)")
    }

    @Test(arguments: [["sidebar", "groupHeader", "memberCount"], ["sidebar", "groupHeader", "unreadCount"]])
    func settingsAndThePaletteListTheTogglesOffByDefault(path: [String]) throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
    }
}
