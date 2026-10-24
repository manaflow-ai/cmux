import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// Draws Go to Workspace (Cmd-P) for "a612" and "612" without the subagent ids (before: what
/// msg 11943's screenshot showed) and with them (after), into one PNG
/// (`CMUX_PALETTE_AGENT_ID_SNAPSHOT_PATH`, else `.build/palette-agent-id.png` in the package), so a
/// fleet step returns it with `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/palette-agent-id.png`.
/// The ranking itself is checked by `PaletteAgentIDSearchTests`.
@MainActor
@Suite(.paletteRanker)
struct PaletteAgentIDSnapshotTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = []
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func workspaces(withIDs: Bool) -> Workspaces {
        let source = Workspaces()
        let rows: [(String, String, String?, String)] = [
            ("w212", "a212 · Chief agents", "Chief agents", "a212"),
            ("w162", "a162 · Cmd-T tabs self-close", "Agents & routing", "a162"),
            ("w112", "a112 · cmux WireGuard mesh", "Agents & routing", "a112"),
            ("w161", "a161 · deploy guard", nil, "a161"),
            ("wcmp", "github.com/manaflow-ai/cmux/compare/5c6369c1c3...c3c07ba184", nil, ""),
            ("w612", "Markdown pane omnibar back", "cmux-next app", "a612"),
            ("w608", "Composer image paste", "cmux-next app", "a608"),
        ]
        source.workspaces = rows.map { id, title, group, agent in
            PaletteWorkspace(id: id, title: title, directory: "/Users/lawrence/fun/cmux", groupName: group,
                             agentID: withIDs && !agent.isEmpty ? agent : nil)
        }
        return source
    }

    private static func render(withIDs: Bool, query: String, windows: inout [NSWindow]) async throws -> NSImage {
        let palette = PaletteController(registry: ActionRegistry.standard(),
                                        sources: PaletteSources(workspaces: workspaces(withIDs: withIDs)), frecencyPersistence: nil)
        palette.show(.workspaces)
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        let view = PaletteContentView(model: palette.model)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        palette.hide()
        return image
    }

    @Test func drawsBeforeAndAfter() async throws {
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        var cells: [[NSImage]] = []
        for query in ["a612", "612"] {
            cells.append([try await Self.render(withIDs: false, query: query, windows: &windows),
                          try await Self.render(withIDs: true, query: query, windows: &windows)])
        }
        let cell = cells[0][0].size
        let label: CGFloat = 28
        let sheet = NSImage(size: NSSize(width: cell.width * 2, height: (cell.height + label) * CGFloat(cells.count)))
        sheet.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
        for (row, query) in ["a612", "612"].enumerated() {
            let y = sheet.size.height - CGFloat(row + 1) * (cell.height + label)
            for (column, title) in ["Before: \"\(query)\"", "After: \"\(query)\""].enumerated() {
                cells[row][column].draw(at: NSPoint(x: CGFloat(column) * cell.width, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                (title as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width + 12, y: y + cell.height + 5), withAttributes: attributes)
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/palette-agent-id.png").path
        let path = ProcessInfo.processInfo.environment["CMUX_PALETTE_AGENT_ID_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        try png.write(to: URL(fileURLWithPath: path))
    }
}
