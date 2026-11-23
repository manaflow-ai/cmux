import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-13: "make cmd shift p roundness same roundness as tabs" (msg 31442), then
/// "density of selected cmd shift p row needs to be concentric" (msg 31478).
///
/// The selected row's highlight is a tab's shape: it rounds with `Metrics.tabCornerRadius`, as a
/// tab pill and a sidebar workspace row do. The panel holds the rows as a card holds its tabs: its
/// corner is the row's plus the inset between them (inner = outer - inset), and that inset is the
/// same on the left, on the right and above the first and below the last row, so the last row's
/// bottom corners nest inside the panel's. A keycap inside a row is concentric with the row. Every
/// value comes from the tab corner and the density's tokens, at every density preset, as drawn.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaletteTabCornerTests {
    @Test(arguments: DensityPreset.allCases)
    func selectedRowIsATabConcentricWithThePanel(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let tab = Metrics.tabCornerRadius
        let inset = PaletteLayout.listInset

        let content = PaletteContentView(model: PaletteModel(persistence: nil))
        content.frame = NSRect(origin: .zero, size: PaletteLayout.windowSize)
        content.layoutSubtreeIfNeeded()

        let row = PaletteTableRowView(frame: NSRect(x: 0, y: 0, width: PaletteLayout.width, height: PaletteLayout.rowHeight))
        row.layout()
        #expect(row.fill.cornerRadius == tab, "\(preset): the selected row is \(row.fill.cornerRadius) pt, a tab \(tab) pt")

        // The same gap on every side of the rows: left and right of a row's fill, above the first and below the last.
        #expect(row.fill.frame.minX == inset && row.bounds.maxX - row.fill.frame.maxX == inset,
                "\(preset): the row's fill sits \(row.fill.frame.minX) pt in, the list's inset is \(inset) pt")
        #expect(content.listContentInsets.top == inset && content.listContentInsets.bottom == inset,
                "\(preset): rows sit \(content.listContentInsets) from the list's edges, \(inset) pt at the sides")

        let concentric = Metrics.corners.nested(in: tab, inset: -inset)
        #expect(content.glass.cornerRadius == concentric,
                "\(preset): the panel is \(content.glass.cornerRadius) pt; concentric with a \(tab) pt row \(inset) pt in it is \(concentric) pt")

        #expect(PaletteLayout.keycapCornerRadius == Metrics.corners.nested(in: tab, inset: Metrics.space1),
                "\(preset): a keycap is not concentric with the row")
    }
}
