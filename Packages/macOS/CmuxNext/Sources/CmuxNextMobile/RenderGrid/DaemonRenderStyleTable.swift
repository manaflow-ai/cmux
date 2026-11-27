import CMUXMobileCore

/// Interns daemon run styles into render-grid style ids. Id 0 is the
/// default style, as the grid format requires.
struct DaemonRenderStyleTable {
    private struct Key: Hashable {
        var fg: String?
        var bg: String?
        var attrs: UInt16
        var underline: Bool
    }

    private(set) var styles: [MobileTerminalRenderGridFrame.Style] = [.default]
    private var ids: [Key: Int] = [Key(fg: nil, bg: nil, attrs: 0, underline: false): 0]

    mutating func id(for run: DaemonRenderFrame.Run) -> Int {
        // Reserved attribute bits are ignored, per render.md.
        let key = Key(fg: run.fg, bg: run.bg, attrs: run.attrs & 0x007F, underline: run.underline != nil)
        if let id = ids[key] { return id }
        let id = styles.count
        ids[key] = id
        let has = { (bit: UInt16) in key.attrs & bit != 0 }
        styles.append(.init(
            id: id,
            foreground: key.fg,
            background: key.bg,
            foregroundSource: key.fg == nil ? nil : .rgb,
            backgroundSource: key.bg == nil ? nil : .rgb,
            bold: has(DaemonRenderAttribute.bold),
            faint: has(DaemonRenderAttribute.faint),
            italic: has(DaemonRenderAttribute.italic),
            underline: key.underline,
            blink: has(DaemonRenderAttribute.blink),
            inverse: has(DaemonRenderAttribute.inverse),
            invisible: has(DaemonRenderAttribute.invisible),
            strikethrough: has(DaemonRenderAttribute.strikethrough)
        ))
        return id
    }
}
