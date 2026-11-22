import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-03: "in cmd shift p 'toggle' options are very confusing, since we don't know
/// the current state." An on/off command's palette row shows whether it is on now, at its
/// trailing edge, on and off alike, and VoiceOver reads the state with the title. The state is
/// read when the palette builds its rows, so a change between two opens shows at the next one.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaletteToggleStateTests {
    private static let width: CGFloat = 640
    private static let height: CGFloat = 32

    /// The `toggleSidebar` row, with its state read from `isOn` when the rows are built.
    private static func row(on isOn: Bool) throws -> PaletteItem {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("toggleSidebar") {}
        ActionTargetTitles.setPaletteState("toggleSidebar", in: registry) { isOn }
        return try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "toggleSidebar" })
    }

    /// The row drawn in a cell, and its pixels right of the title's column (where a state shows).
    private static func drawn(_ item: PaletteItem) throws -> (cell: PaletteRowCell, trailing: [UInt32]) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = PaletteRowCell(frame: frame)
        window.contentView = cell
        cell.configure(PaletteRow(item: item, highlights: [], score: 0), isSelected: false)
        cell.layoutSubtreeIfNeeded()
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        var pixels: [UInt32] = []
        let start = Int(CGFloat(rep.pixelsWide) * 0.55)
        for y in 0..<rep.pixelsHigh {
            for x in start..<rep.pixelsWide {
                var p = [Int](repeating: 0, count: 4)
                rep.getPixel(&p, atX: x, y: y)
                pixels.append(UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3]))
            }
        }
        return (cell, pixels)
    }

    @Test func theRowSaysWhetherTheCommandIsOnNow() throws {
        let on = try Self.drawn(Self.row(on: true))
        let off = try Self.drawn(Self.row(on: false))
        #expect(on.cell.accessibilityValue() as? String == PaletteStrings.on)
        #expect(off.cell.accessibilityValue() as? String == PaletteStrings.off)
        // The trailing edge draws differently on and off: an off command shows its state too.
        #expect(on.trailing != off.trailing, "the row's trailing edge is the same on and off")
    }

    /// A command that is not on/off keeps a plain row: no state, nothing read out.
    @Test func aPlainCommandShowsNoState() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("toggleSidebar") {}
        let item = try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "toggleSidebar" })
        let plain = try Self.drawn(item)
        #expect(plain.cell.accessibilityValue() == nil)
    }
}
