import AppKit
import CmuxNextDesign

// Row setters that write only a changed value (a ChromeLabel skips equal values itself). An AppKit label (NSTextField) marks its layer for a new
// backing-store draw on every text, color or font set, equal or not, and a row's `updateLayer` and
// `configure` run on each layout, hover and status tick. With these, a row that moves or keeps its
// content keeps its drawn layers (sidebar perf round 4).
extension ShownText {
    func setString(_ value: String) { if stringValue != value { stringValue = value } }
    func setColor(_ value: NSColor) { if textColor != value { textColor = value } }
    func setFont(_ value: NSFont) { if font != value { font = value } }
}

extension NSImageView {
    func setTint(_ value: NSColor?) { if contentTintColor != value { contentTintColor = value } }
}
