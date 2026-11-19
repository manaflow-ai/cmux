import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Shots of the Sidebar States Playground for Lawrence msg 19746 ("show me all the possible sidebar states, and i will
/// critique their sizings ... legit representative screenshots in swift"): the playground view itself
/// (``SidebarStatesPlaygroundView``, the Debug menu's window) hosted in a real window, each sheet captured whole
/// (`sheet-light.png`, `sheet-dark.png`), then one crop per appearance and density with the state names beside it
/// (`light-compact.png`, ...), the pinned row with its hover card at each density (`light-pinned-card.png`), and the App's
/// Home filter section (a939's Unread filter: `home-filter-light.png`, `home-filter-dark.png`). `measurements.tsv` lists every trailing mark's measured frame and ink, also printed as
/// `SBSTATES|` lines. `CMUX_TEST_REQUIRE_GUI=1`; bundled to `sidebar-states-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarStatesGalleryTests {
    static func themes() throws -> SidebarStatesPlaygroundThemes {
        var colors: [String: ThemeFileColors] = [:]
        for name in [SidebarStatesPlaygroundThemes.lightName, SidebarStatesPlaygroundThemes.darkName] {
            let text = try String(contentsOf: AANestedGroupsGalleryTests.repoRoot.appending(path: "Resources/cmux-themes/\(name)"),
                                  encoding: .utf8)
            colors[name] = try #require(ThemeFileColors(name: name, themeFile: text))
        }
        return SidebarStatesPlaygroundThemes(colors: colors)
    }

    /// `view`'s pixels at 2x at least, so the cells' 2x row shots keep their pixels on a 1x fleet display.
    static func capture(_ view: NSView) throws -> CGImage {
        let scale = max(2, view.window?.backingScaleFactor ?? 1)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// The parts of `sheet` under `rects` (the sheet's flipped points), side by side.
    static func crop(_ sheet: NSView, _ image: CGImage, _ rects: [NSRect]) throws -> CGImage {
        let scale = CGFloat(image.width) / sheet.bounds.width
        let parts = try rects.map { rect in
            try #require(image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                                                   height: rect.height * scale).integral))
        }
        let width = parts.map(\.width).reduce(0, +), height = parts.map(\.height).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var x = 0
        for part in parts {
            ctx.draw(part, in: CGRect(x: x, y: height - part.height, width: part.width, height: part.height))
            x += part.width
        }
        return try #require(ctx.makeImage())
    }

    /// One `SBSTATES|` line per trailing mark (or per row with none).
    static func measurements(_ sheet: SidebarStatesPlaygroundSheetView) -> [String] {
        var lines: [String] = []
        for column in sheet.columns {
            for state in SidebarStatesPlaygroundState.allCases {
                guard let cell = sheet.cells[column]?[state] else { continue }
                let head = [sheet.appearanceKind.rawValue, column.density.rawValue, column.textSize.rawValue, state.rawValue,
                            cell.rowView ?? "-", String(format: "%.0f", cell.size.height - 2 * SidebarStatesPlaygroundRenderer.rowPad)]
                if let card = cell.card {
                    let rows = "tab rows " + card.tabRowHeights.map { SidebarStatesPlaygroundMark.number($0) }.joined(separator: ", ")
                    lines.append((head + ["card:WorkspaceHoverCardView", "-", SidebarStatesPlaygroundMark.text(card.frame.size), rows,
                                          String(format: "%.2f", card.frame.minY - cell.rowFrame.minY)]).joined(separator: "\t"))
                }
                if cell.marks.isEmpty && cell.bars.isEmpty && cell.card == nil { lines.append((head + ["-", "-", "-", "-", "-"]).joined(separator: "\t")) }
                for bar in cell.bars {
                    let radii = String(format: "top %.2f / bottom %.2f", bar.topRadius, bar.bottomRadius)
                    lines.append((head + ["bar:" + bar.view, "-", SidebarStatesPlaygroundMark.text(bar.frame.size), radii, "-"])
                        .joined(separator: "\t"))
                }
                for mark in cell.marks {
                    let ink = mark.ink.map { SidebarStatesPlaygroundMark.text($0) } ?? "-"
                    let center = cell.columnGuideX.map { String(format: "%.2f", mark.frame.midX - $0) } ?? "-"
                    lines.append((head + [mark.view, mark.state ?? "-", SidebarStatesPlaygroundMark.text(mark.frame.size), ink, center])
                        .joined(separator: "\t"))
                }
            }
        }
        return lines
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil; StatusIndicatorAppearance.shared.refresh() }
        // The favicon styles sheets set `sidebar.faviconStyle` per column: the store takes overrides only once it is
        // active and knows the key, as the app's is from launch.
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        // The shared config caches whether loops run; read it again with Reduce Motion off, so busy rows draw the spinner.
        StatusIndicatorAppearance.shared.refresh()
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-states-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer = SidebarStatesPlaygroundRenderer(design: .shared, themes: try Self.themes())
        let playground = SidebarStatesPlaygroundView(renderer: renderer, sections: [HomeFilterPlaygroundSection().section()])
        let stateSheets = SidebarStatesPlaygroundAppearance.allCases.compactMap { playground.sheets[$0] }
        #expect(stateSheets.count == 2)
        // The favicon styles sheets (`sidebar.faviconStyle`, Lawrence msg 19869), one per style at every density and text
        // size, written as sheet-favicons-<appearance>-<style>.png.
        let faviconSheets = SidebarStatesPlaygroundAppearance.allCases.flatMap { playground.faviconSheets[$0] ?? [] }
        #expect(faviconSheets.count == 2 * SidebarFaviconStyle.allCases.count)
        // The Home filter section's sheets, written as home-filter-<appearance>.png.
        let homeFilterSheets = SidebarStatesPlaygroundAppearance.allCases.compactMap { playground.sectionSheets[$0]?.first }
        #expect(homeFilterSheets.count == 2)
        for sheet in homeFilterSheets {
            #expect(sheet.columns.count == SidebarDensity.allCases.count * SidebarTextSize.allCases.count)
            for column in sheet.columns {
                let looks = sheet.cells[column] ?? []
                #expect(looks.count == 3 && looks.allSatisfy { $0.image != nil }, "\(sheet.appearanceKind) \(column.title): a look was not drawn")
                for (title, look) in zip(sheet.lookTitles, looks) {
                    print("SBHOMEFILTER|\(sheet.appearanceKind.rawValue)|\(column.density.rawValue)|\(column.textSize.rawValue)|\(title)|"
                          + SidebarStatesPlaygroundMark.text(look.size))
                }
            }
        }
        let sheets: [NSView] = stateSheets + faviconSheets + homeFilterSheets
        // A window as large as the playground's content, so no sheet is clipped by its scroll view.
        let size = NSSize(width: sheets.map(\.frame.width).max() ?? 1200,
                          height: sheets.map(\.frame.height).reduce(0, +) + 80)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        playground.frame = NSRect(origin: .zero, size: size)
        window.contentView = playground
        window.orderFrontRegardless()
        playground.layoutSubtreeIfNeeded()
        var rows = ["appearance\tdensity\ttextSize\tstate\trowView\trowHeight\tmark\tmarkState\tframe\tink\tcenterFromColumn"]
        for sheet in homeFilterSheets {
            sheet.layoutSubtreeIfNeeded()
            sheet.display()
            try AAGroupHeaderDensityGalleryTests.write(try Self.capture(sheet),
                                                       to: out.appending(path: "home-filter-\(sheet.appearanceKind.rawValue).png"))
        }
        for sheet in stateSheets + faviconSheets {
            sheet.layoutSubtreeIfNeeded()
            sheet.display()
            let image = try Self.capture(sheet)
            let name = sheet.appearanceKind.rawValue
            if faviconSheets.contains(where: { $0 === sheet }) {
                let style = try #require(sheet.columns.first?.faviconStyle)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "sheet-favicons-\(name)-\(style.rawValue).png"))
                continue
            }
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "sheet-\(name).png"))
            for density in SidebarDensity.allCases {
                let frame = try #require(sheet.densityFrames[density])
                let crop = try Self.crop(sheet, image, [sheet.labelFrame, frame])
                try AAGroupHeaderDensityGalleryTests.write(crop, to: out.appending(path: "\(name)-\(density.rawValue).png"))
            }
            // Each density's pinned row with its hover card beside it, at the three text sizes.
            try AAGroupHeaderDensityGalleryTests.write(try Self.crop(sheet, image, [sheet.cardSectionFrame]),
                                                       to: out.appending(path: "\(name)-pinned-card.png"))
            for line in Self.measurements(sheet) {
                rows.append(line)
                print("SBSTATES|" + line.replacingOccurrences(of: "\t", with: "|"))
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: out.appending(path: "measurements.tsv"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-states-gallery.tar", "sidebar-states-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
