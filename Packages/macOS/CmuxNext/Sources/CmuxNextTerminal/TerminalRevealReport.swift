public import CoreGraphics

/// What a terminal shows at the moment it is shown again (a tab, pane or workspace switched back to,
/// a window unhidden): the scales it draws and shows at, the frame it kept while hidden, and its font.
///
/// Reported once per reveal (``TerminalSessionDelegate/terminalSession(_:revealed:)``) and, when the
/// pane still shows no frame 500 ms later, again as a blank pane
/// (``TerminalSessionDelegate/terminalSession(_:blankAfterReveal:)``), or, when it drew and its layer's
/// scale is still not the one Ghostty draws at, as a second reveal report with ``framesSinceReveal`` above 0.
/// It holds numbers only, never terminal text, so it may go to logs and crash telemetry as is.
///
/// ```swift
/// let report = session.surfaceView.revealReport(saved: .kept)
/// if !report.scalesAgree { logger.error("\(report.message)") }
/// ```
public struct TerminalRevealReport: Sendable, Equatable {
    /// What became of the frame the layer showed when the terminal was hidden.
    public enum SavedFrame: String, Sendable, Equatable {
        /// The terminal showed no frame when it was hidden (or it was given to another view).
        case none
        /// The frame was kept (made non-volatile again) and shows at once.
        case kept
        /// The system discarded the frame's pages while it was hidden: the layer shows nothing until Ghostty draws.
        case purged
        /// A newer frame replaced it while hidden: that one shows.
        case replaced
    }

    /// The display scale Ghostty draws at (`ghostty_surface_set_content_scale`); nil before it was set.
    public var contentScale: CGFloat?
    /// The scale the surface layer shows its frame at (`contentsScale`); nil without a layer.
    public var layerScale: CGFloat?
    /// The window's backing scale; nil out of a window.
    public var windowScale: CGFloat?
    /// The frame kept while the terminal was hidden.
    public var savedFrame: SavedFrame
    /// A held frame (a last frame, a swapped-out surface's frame) covers the surface.
    public var holdingFrame: Bool
    /// The layer shows a frame now.
    public var hasFrame: Bool
    /// The terminal's font size in points: the configured size times its zoom; nil before the config loaded.
    public var fontPoints: Double?
    /// The terminal's font zoom, nil at the configured size.
    public var fontScale: Double?
    /// The surface view's size in points.
    public var viewSize: CGSize
    /// Frames Ghostty showed on the layer since the reveal (its present callback, ``TerminalPresents``): 0 in the
    /// report made at the reveal itself.
    public var framesSinceReveal: UInt64

    public init(contentScale: CGFloat?, layerScale: CGFloat?, windowScale: CGFloat?, savedFrame: SavedFrame,
                holdingFrame: Bool, hasFrame: Bool, fontPoints: Double?, fontScale: Double?, viewSize: CGSize,
                framesSinceReveal: UInt64 = 0) {
        self.contentScale = contentScale
        self.layerScale = layerScale
        self.windowScale = windowScale
        self.savedFrame = savedFrame
        self.holdingFrame = holdingFrame
        self.hasFrame = hasFrame
        self.fontPoints = fontPoints
        self.fontScale = fontScale
        self.viewSize = viewSize
        self.framesSinceReveal = framesSinceReveal
    }

    /// Ghostty draws at the window's scale, and the layer shows its frame at the scale it was drawn at: text has its
    /// true size. False is the tiny (or huge) text class: a frame drawn at one scale shown at another.
    ///
    /// The layer's scale is Ghostty's: a new one lands with the first frame drawn at it. So at the reveal itself
    /// (``framesSinceReveal`` 0) the layer may still show its kept frame at that frame's own scale, which is no
    /// mismatch; once a frame showed since the reveal, the layer's scale must be the one Ghostty draws at.
    public var scalesAgree: Bool {
        guard let contentScale, let layerScale, let windowScale else { return true }
        guard abs(contentScale - windowScale) < 0.01 else { return false }
        return framesSinceReveal == 0 || abs(contentScale - layerScale) < 0.01
    }

    /// Worth a warning: the scales disagree (tiny or huge text) or the kept frame was discarded (an empty pane until
    /// Ghostty draws).
    public var isSuspect: Bool { !scalesAgree || savedFrame == .purged }

    /// The pane shows nothing: no frame on the layer, none held over it, and Ghostty showed none since the reveal.
    public var isBlank: Bool { !hasFrame && !holdingFrame && framesSinceReveal == 0 }

    /// One log line, numbers only.
    public var message: String {
        func number(_ value: CGFloat?) -> String { value.map { String(format: "%.2f", Double($0)) } ?? "-" }
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        return "content_scale=\(number(contentScale)) layer_scale=\(number(layerScale)) window_scale=\(number(windowScale))"
            + " scales_agree=\(scalesAgree) saved_frame=\(savedFrame.rawValue) holding_frame=\(holdingFrame)"
            + " has_frame=\(hasFrame) font_points=\(number(fontPoints)) font_scale=\(number(fontScale))"
            + " view=\(Int(viewSize.width.rounded()))x\(Int(viewSize.height.rounded()))"
            + " frames_since_reveal=\(framesSinceReveal)"
    }

    /// Key-value data for a crash-telemetry breadcrumb, numbers only.
    public var fields: [String: String] {
        var fields: [String: String] = [
            "scales_agree": String(scalesAgree), "saved_frame": savedFrame.rawValue,
            "holding_frame": String(holdingFrame), "has_frame": String(hasFrame),
            "view": "\(Int(viewSize.width.rounded()))x\(Int(viewSize.height.rounded()))",
            "frames_since_reveal": String(framesSinceReveal),
        ]
        if let contentScale { fields["content_scale"] = String(format: "%.2f", Double(contentScale)) }
        if let layerScale { fields["layer_scale"] = String(format: "%.2f", Double(layerScale)) }
        if let windowScale { fields["window_scale"] = String(format: "%.2f", Double(windowScale)) }
        if let fontPoints { fields["font_points"] = String(format: "%.2f", fontPoints) }
        if let fontScale { fields["font_scale"] = String(format: "%.2f", fontScale) }
        return fields
    }
}
