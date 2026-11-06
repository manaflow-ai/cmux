import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextImportSuggestions
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the sidebar's Import from Conductor note for Lawrence 2026-11-05 ("in general, we dont want to mention
/// others by name so prominently"): the note before, the shipped wording (`ConductorImportStrings`, variant a) and
/// three other wordings, none with another product in the title or as the subject, at sidebars 220 and 260 pt wide,
/// dark and light. Written under `conductor-note-gallery/` with `all.png`, bundled to `conductor-note-gallery.tar`
/// for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAConductorNoteGalleryTests {
    static func note(title: String, detail: String) -> SidebarNoticeCard {
        SidebarNoticeCard(id: "import.conductorNote", symbol: "square.and.arrow.down", title: title, detail: detail,
                          actions: [SidebarNoticeCard.Action(id: "open", title: ConductorImportStrings.noteOpen, prominent: true)],
                          dismissLabel: ConductorImportStrings.noteClose)
    }

    static func variants() -> [(String, SidebarNoticeCard)] {
        [
            ("0-before", note(title: "Bring your Conductor workspaces",
                              detail: "Conductor Cloud shuts down on November 20. Settings › Import opens your workspaces here, in place.")),
            ("a-shipped", note(title: ConductorImportStrings.noteTitle, detail: ConductorImportStrings.noteDetail)),
            ("b-settings-first", note(title: "Bring your workspaces",
                                      detail: "Settings › Import opens the workspaces you already have here, in place.")),
            ("c-pick-up", note(title: "Pick up where you left off",
                               detail: "Import your workspaces from Settings › Import. They open here, in place, on their branches.")),
            ("d-import-title", note(title: "Import your workspaces",
                                    detail: "They open here in place, on their branches, with their chats.")),
        ]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "conductor-note-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (name, card) in Self.variants() {
                for width in AASidebarNoticeCardGalleryTests.widths {
                    let image = try AASidebarNoticeCardGalleryTests.notice(card, width: width, placement: .above, dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    images.append(image)
                }
            }
            columns.append(images)
        }
        // Every still in a column, dark on the left and light on the right.
        let gap = 16
        let cellW = columns.flatMap { $0 }.map(\.width).max() ?? 1
        let heights = columns[0].map(\.height)
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: heights.reduce(0, +) + (heights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, images) in columns.enumerated() {
            var top = ctx.height - gap
            for image in images {
                top -= image.height
                ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top, width: image.width, height: image.height))
                top -= gap
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "conductor-note-gallery.tar", "conductor-note-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
