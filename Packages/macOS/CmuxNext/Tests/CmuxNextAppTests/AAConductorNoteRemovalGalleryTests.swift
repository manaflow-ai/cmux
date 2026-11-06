import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Before and after for Leo 2026-11-05 ("but just.. don't show your card?"): the sidebar's notice slot with the
/// Import from Conductor note as it shipped, and the same slot now, which shows the next card in the order (today's
/// tip). Sidebars 220 and 260 pt wide, dark and light. Throwaway gallery, not for merge.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAConductorNoteRemovalGalleryTests {
    static let before = SidebarNoticeCard(id: "conductor-import", symbol: "square.and.arrow.down", title: "Bring your Conductor workspaces",
                                          detail: "Conductor Cloud shuts down on November 20. Settings › Import opens your workspaces here, in place.",
                                          actions: [SidebarNoticeCard.Action(id: "open-import", title: "Open Import", prominent: true)],
                                          dismissLabel: "Don’t Show Again")

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "conductor-note-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let after = try #require(AASidebarNoticeCardGalleryTests.cards().first { $0.0 == "card-4-tip" }?.1)
        for dark in [true, false] {
            for width in AASidebarNoticeCardGalleryTests.widths {
                for (name, card) in [("before", Self.before), ("after", after)] {
                    let image = try AASidebarNoticeCardGalleryTests.notice(card, width: width, placement: .above, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "conductor-note-gallery.tar", "conductor-note-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
