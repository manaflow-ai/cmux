import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar draws every name in the app's one UI face, the macOS system font (Lawrence 2026-11-07: "default fonts
/// on cmux for everything should be macos default, not inter, this applies to everything"). Group headers, their
/// member count and a workspace title with a weight of its own once drew in another face than the rows beside them.
@MainActor @Suite struct SidebarUIFontFaceTests {
    private let systemFamily = NSFont.systemFont(ofSize: 13).familyName

    @Test func groupHeaderNameAndCountDrawInTheUIFace() {
        let name = SidebarStyle.groupHeaderFont(barHeight: 26)
        #expect(name.familyName == systemFamily)
        #expect(SidebarStyle.groupHeaderCountFont(name: name).familyName == systemFamily)
    }

    @Test func aWeightedTitleDrawsInTheUIFace() {
        let title = SidebarStyle.titleFont(weight: .bold)
        #expect(title.familyName == systemFamily)
        #expect(title.pointSize == SidebarStyle.titleFont.pointSize)
    }
}
