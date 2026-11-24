import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-24 (ask-97938b6c84): terminal agent chats draw their mark as a reverse-video tile. The tile fills
/// its slot in the row's ink, the mark cut out to true transparency (the row's fill shows through), corners round.
@MainActor @Suite struct TerminalMarkTileTests {
    /// A solid square standing in for a mark: every pixel of its box is ink, so its whole box must come out clear.
    private static func solidMark(pixels: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return try #require(context.makeImage())
    }

    /// The alpha of every pixel, row 0 at the top.
    private static func alpha(_ image: CGImage) throws -> (Int, Int) -> UInt8 {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let copy = bytes
        return { x, y in copy[(y * w + x) * 4 + 3] }
    }

    @Test func aSixteenSlotTileHoldsATwelveMarkWithFourCorners() {
        #expect(TerminalMarkTile.markSide(slot: 16) == 12)
        #expect(TerminalMarkTile.cornerRadius(slot: 16) == 4)
        #expect(TerminalMarkTile.markSide(slot: 32) == 20)
        #expect(TerminalMarkTile.cornerRadius(slot: 32) == 8)
        #expect(TerminalMarkTile.holds(slot: 16))
        #expect(!TerminalMarkTile.holds(slot: 12), "a 12 slot keeps the bare mark")
    }

    @Test(arguments: [CGFloat(1), 2]) func theTileFillsItsSlotWithTheMarkKnockedOut(scale: CGFloat) throws {
        let slot: CGFloat = 16
        let mark = try Self.solidMark(pixels: Int(TerminalMarkTile.markSide(slot: slot) * scale))
        let tile = try #require(TerminalMarkTile.image(mark: mark, slot: slot, scale: scale, ink: CGColor(gray: 1, alpha: 1)))
        let side = Int(slot * scale)
        #expect(tile.width == side && tile.height == side, "the tile is the slot, at the screen's scale")
        let alpha = try Self.alpha(tile)
        #expect(alpha(side / 2, side / 2) == 0, "the mark's centre is clear: the row shows through")
        #expect(alpha(0, 0) == 0, "the corner rounds off")
        #expect(alpha(side / 2, 0) == 255, "the top edge's midpoint is tile")
        #expect(alpha(0, side / 2) == 255, "the leading edge's midpoint is tile")
    }

    @Test func theSidebarDrawsTheTileOnlyForATerminalAgentInASlotThatHoldsOne() {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-terminal"), title: "Fix the flaky restore test")
        workspace.agentBrand = "claude"
        #expect(!WorkspaceRowView.drawsTerminalTile(workspace, variant: .replacesStatus), "an agent chat keeps its bare mark")
        workspace.agentInTerminal = true
        #expect(WorkspaceRowView.drawsTerminalTile(workspace, variant: .off) == false)
        #expect(WorkspaceRowView.drawsTerminalTile(workspace, variant: .replacesStatus) == TerminalMarkTile.holds(slot: SidebarStyle.statusGlyphSize))
        let tile = WorkspaceRowView.terminalTileMark(workspace, slot: 16)
        #expect(tile?.size == NSSize(width: 16, height: 16))
        #expect(tile?.isTemplate == true, "the row tints it with its ink")
        #expect(WorkspaceRowView.terminalTileKey(workspace, slot: 16) == WorkspaceRowView.terminalTileKey(workspace, slot: 16),
                "a row configured again keeps its tile")
    }
}
