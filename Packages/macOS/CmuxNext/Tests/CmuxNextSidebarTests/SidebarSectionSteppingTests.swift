@testable import CmuxNextSidebar
import Testing

/// R119: Cmd-Ctrl-] / Cmd-Ctrl-[ step to the next / previous item inside the
/// section that holds the current item, in every items section (top, bottom,
/// user sections), wrapping at the ends and skipping items that do not draw
/// or do not resolve. The workspaces section has no items: the caller steps
/// workspaces there.
struct SidebarSectionSteppingTests {
    static let doc = SidebarLayoutDocument(sections: [
        LayoutSection(id: LayoutSectionID("top"), region: .top, items: [
            LayoutItem(id: LayoutItemID("home"), ref: .app("cmux/home")),
            LayoutItem(id: LayoutItemID("store"), ref: .app("cmux/app-store")),
            LayoutItem(id: LayoutItemID("hidden"), ref: .app("x/hidden")),
            LayoutItem(id: LayoutItemID("hist"), ref: .builtIn(.history)),
        ]),
        LayoutSection(id: LayoutSectionID("ws"), region: .middle, content: .workspaces),
        LayoutSection(id: LayoutSectionID("bottom"), region: .bottom, items: [
            LayoutItem(id: LayoutItemID("settings"), ref: .builtIn(.settings)),
        ]),
    ])
    static func step(_ from: String, _ by: Int) -> String? {
        SidebarSectionStepping.step(from: LayoutItemID(from), by: by, in: doc, skip: { $0.id == LayoutItemID("hidden") })?.rawValue
    }

    @Test func nextAndPreviousStayInTheSectionAndWrap() {
        #expect(Self.step("home", 1) == "store")
        #expect(Self.step("store", 1) == "hist", "hidden item skipped")
        #expect(Self.step("hist", 1) == "home", "wraps to the first")
        #expect(Self.step("home", -1) == "hist", "wraps to the last")
        #expect(Self.step("hist", -1) == "store")
    }

    @Test func aSectionWithOneItemOrAnUnknownItemHasNoStep() {
        #expect(Self.step("settings", 1) == nil)
        #expect(Self.step("missing", 1) == nil)
    }
}
