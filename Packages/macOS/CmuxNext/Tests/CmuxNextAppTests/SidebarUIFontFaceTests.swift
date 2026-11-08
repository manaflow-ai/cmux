import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar draws every name in the app's one UI face, the bundled Inter (`BundledFonts`, Leo 2026-10-21:
/// "WE SAID INTER, WITH SOME AMOUNT [of tracking], AND WE BUNDLED SOME STUFF IN"). Group headers, their member
/// count and a workspace title with a weight of its own were still made with `NSFont.systemFont`, so they drew in
/// SF beside Inter rows. Leo 2026-11-05: "I just feel like the Apple system font, like especially for the
/// sidebar, it just looks a little bit whack."
@MainActor @Suite struct SidebarUIFontFaceTests {
    @Test func groupHeaderNameAndCountDrawInTheUIFace() throws {
        try #require(BundledFonts.isRegistered)
        let name = SidebarStyle.groupHeaderFont(barHeight: 26)
        #expect(name.familyName == TypeScale.fileFamily)
        #expect(SidebarStyle.groupHeaderCountFont(name: name).familyName == TypeScale.fileFamily)
    }

    @Test func aWeightedTitleDrawsInTheUIFace() throws {
        try #require(BundledFonts.isRegistered)
        let title = SidebarStyle.titleFont(weight: .bold)
        #expect(title.familyName == TypeScale.fileFamily)
        #expect(title.pointSize == SidebarStyle.titleFont.pointSize)
    }
}
