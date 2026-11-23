import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Shots of the Sidebar States Playground's "Workspace colors" sheet (Lawrence 2026-11-20, "make many versions of
/// 'colors' we need this to be better"): each treatment (``WorkspaceColorPlaygroundSection/variants``) drawn by the
/// playground's own renderer with real ``WorkspaceRowView``s at the default density and text size, in the light and
/// dark sheets' themes, written as `NN-<appearance>.png` (`00-light.png` is the app's own look) with `variants.tsv`
/// naming each. `CMUX_TEST_REQUIRE_GUI=1`; bundled to `workspace-color-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceColorGalleryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "workspace-color-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = SidebarStatesPlaygroundRenderer(design: .shared, themes: try AASidebarStatesGalleryTests.themes())
        let section = WorkspaceColorPlaygroundSection().section()
        let column = SidebarStatesPlaygroundColumn(density: .compact, textSize: .standard)
        var names = ["index\tvariant"]
        for (index, look) in section.looks.enumerated() { names.append(String(format: "%02d", index) + "\t" + look.title) }
        for appearance in SidebarStatesPlaygroundAppearance.allCases {
            let cells = renderer.lookCells(section, column, appearance)
            #expect(cells.count == section.looks.count)
            for (index, cell) in cells.enumerated() {
                let image = try #require(cell.image, "\(appearance) \(section.looks[index].title): not drawn")
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: String(format: "%02d-%@.png", index,
                                                                                                appearance.rawValue)))
            }
        }
        try (names.joined(separator: "\n") + "\n").write(to: out.appending(path: "variants.tsv"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "workspace-color-gallery.tar", "workspace-color-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
