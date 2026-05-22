import AppKit

enum ResizeVisualOracle {
    static let enabled =
        ProcessInfo.processInfo.environment["MINIMAL_BROWSER_RESIZE_VISUAL_ORACLE"] == "1"

    static let chromeBandColor = NSColor(calibratedRed: 0, green: 1, blue: 0.35, alpha: 1)
    static let mainSurfaceBandColor = NSColor(calibratedRed: 0, green: 0.34, blue: 1, alpha: 1)
    static let stackBandColor = NSColor(calibratedRed: 0.61, green: 0, blue: 1, alpha: 1)
    static let hostBandColor = NSColor(calibratedRed: 1, green: 0.55, blue: 0, alpha: 1)
}

final class ResizeVisualOracleBandView: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
