@testable import CmuxNextSidebar
import Testing

/// `sectionAdd` of a section that is not an item list, on the sidebar document (unimplemented
/// audit row 15). An app-contributed section (`content: app`, `contribution: <app>#<section>`) is
/// a document section of kind `app` (the daemon's `SectionKind::App`); it was refused with "this
/// sidebar setting is not available in the new sidebar yet". A section with a bad contribution, or
/// a second workspace list, is refused for what it is, not as a missing feature.
@MainActor @Suite struct SidebarDocAppSectionAddTests {
    static let layout = SidebarLayoutDocument.defaults

    static func appSection(_ contribution: String?, items: [LayoutItem] = []) -> LayoutSection {
        LayoutSection(id: LayoutSectionID("sec_weather"), title: "Weather", region: .top, content: .app, contribution: contribution, items: items)
    }

    @Test func anAppSectionIsAddedAsAnAppSectionOfTheDocument() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let ops = try store.docOps(for: [.sectionAdd(Self.appSection("acme.weather#forecast"), index: 0)], layout: Self.layout)
        try #require(ops.count == 1, "\(ops)")
        #expect(ops[0]["op"] as? String == "section.add")
        let section = try #require(ops[0]["section"] as? [String: Any])
        #expect(section["id"] as? String == "sec_weather")
        #expect(section["title"] as? String == "Weather")
        #expect(section["region"] as? String == "top")
        let kind = try #require(section["kind"] as? [String: String], "\(section)")
        #expect(kind == ["type": "app", "contribution": "acme.weather#forecast"])
    }

    @Test(arguments: [nil, "", "acme.weather", "#forecast"])
    func anAppSectionWithoutAValidContributionIsRefusedAsSuch(_ contribution: String?) {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        do {
            let ops = try store.docOps(for: [.sectionAdd(Self.appSection(contribution), index: 0)], layout: Self.layout)
            Issue.record("an app section with contribution \(String(describing: contribution)) was planned: \(ops)")
        } catch {
            #expect(error != .unsupported, "an invalid app section reads as a missing feature")
        }
    }

    /// An app section holds no items: one added with items is refused, nothing is sent.
    @Test func anAppSectionWithItemsIsRefusedAsSuch() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let item = LayoutItem(id: LayoutItemID("itm_x"), ref: .app("cmux/app-store"))
        do {
            let ops = try store.docOps(for: [.sectionAdd(Self.appSection("acme.weather#forecast", items: [item]), index: 0)], layout: Self.layout)
            Issue.record("an app section with items was planned: \(ops)")
        } catch {
            #expect(error != .unsupported, "an app section with items reads as a missing feature")
        }
    }

    /// The workspace list is exactly one section (L1): a second one is refused as that.
    @Test func aSecondWorkspaceListIsRefusedAsTheWorkspaceList() {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let section = LayoutSection(id: LayoutSectionID("sec_more"), region: .middle, content: .workspaces)
        do {
            let ops = try store.docOps(for: [.sectionAdd(section, index: 0)], layout: Self.layout)
            Issue.record("a second workspace list was planned: \(ops)")
        } catch {
            #expect(error != .unsupported, "a second workspace list reads as a missing feature")
        }
    }
}
