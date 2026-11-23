public import AppKit
public import CmuxNextDesign

/// Why Home is unavailable (an owner too old for this app, a migration notice): one centred reason in the middle of the
/// pane, hidden while Home is available. A long reason wraps in a narrow pane instead of clipping.
public final class HomeUnavailableLabel: ChromeLabel {
    /// How many times ``place(in:)`` measured the text (HomeResizeChromeWasteTests).
    public private(set) var measures = 0

    /// The label, hidden until the owner answers: a daemon still connecting is not one too old.
    public static func make(_ text: String) -> HomeUnavailableLabel {
        let label = HomeUnavailableLabel(labelWithString: "")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.wraps = true
        label.stringValue = text
        label.isHidden = true
        return label
    }

    /// Centres the reason in `bounds`, 24 pt in from each side. Hidden, it is not measured or marked for display: a pane
    /// width change lays Home out once a frame, and its owner asks for a layout when it shows the reason.
    public func place(in bounds: NSRect) { // perf-hot: 1ms motion-frame (each frame of a pane width change of the Home)
        guard !isHidden else { return }
        measures += 1
        let inset: CGFloat = 24
        let width = max(0, bounds.width - 2 * inset)
        preferredMaxLayoutWidth = width
        let height = ceil(size(forWidth: width).height)
        frame = NSRect(x: inset, y: (bounds.height - height) / 2, width: width, height: height)
    }
}
