import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Draws Cmd-Shift-P New Group Chat's Members step, light and dark: on open (who can join, listed)
/// and after choosing Chief and Aziz (two chips, Continue row first), into one PNG
/// (`CMUX_PALETTE_MEMBERS_SNAPSHOT_PATH`, else `.build/palette-members.png` in the package), so a
/// fleet step returns it with `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/palette-members.png`.
/// The behavior is checked by `PaletteMemberPickerTests`.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteMemberPickerSnapshotTests {
    private static func page(chosen: [String]) throws -> PalettePageSpec {
        let registry = ActionRegistry.standard()
        registry.argumentSuggestions = { source in
            source == ActionSuggestions.homeMembers
                ? [ActionEnumCase(value: "chief_1", title: "Chief"), ActionEnumCase(value: "chief_2", title: "Unii"),
                   ActionEnumCase(value: "user_aziz", title: "Aziz"), ActionEnumCase(value: "user_leo", title: "Leo"),
                   ActionEnumCase(value: "user_austin", title: "Austin")]
                : []
        }
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "home.createGroup" })
        let flow = PaletteArgumentFlow(registry: registry, descriptor: descriptor, targets: nil)
        guard case .push(var page) = flow.effect(collected: ActionInvocation()) else { throw CancellationError() }
        for title in chosen {
            let row = try #require((page.providers.first as? StaticPaletteProvider)?.itemsList.first { $0.title == title })
            guard case .replace(let next) = row.primary.effect.resolved() else { throw CancellationError() }
            page = next
        }
        return page
    }

    private static func render(chosen: [String], dark: Bool, windows: inout [NSWindow]) async throws -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(page: try page(chosen: chosen))
        await palette.model.settle()
        let view = PaletteContentView(model: palette.model)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    @Test func drawsLightAndDark() async throws {
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        let states: [(String, [String])] = [("On open", []), ("Chief and Aziz chosen", ["Chief", "Aziz"])]
        var cells: [[NSImage]] = []
        for (_, chosen) in states {
            cells.append([try await Self.render(chosen: chosen, dark: false, windows: &windows),
                          try await Self.render(chosen: chosen, dark: true, windows: &windows)])
        }
        let cell = cells[0][0].size
        let label: CGFloat = 28
        let sheet = NSImage(size: NSSize(width: cell.width * 2, height: (cell.height + label) * CGFloat(cells.count)))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
        for (row, state) in states.enumerated() {
            let y = sheet.size.height - CGFloat(row + 1) * (cell.height + label)
            for (column, mode) in ["Light", "Dark"].enumerated() {
                cells[row][column].draw(at: NSPoint(x: CGFloat(column) * cell.width, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                ("\(mode): \(state.0)" as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width + 12, y: y + cell.height + 5),
                                                         withAttributes: attributes)
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/palette-members.png").path
        let path = ProcessInfo.processInfo.environment["CMUX_PALETTE_MEMBERS_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        try png.write(to: URL(fileURLWithPath: path))
    }
}
