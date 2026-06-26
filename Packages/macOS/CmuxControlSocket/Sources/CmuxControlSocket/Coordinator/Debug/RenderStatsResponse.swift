#if DEBUG
public import Foundation

/// The JSON payload `render_stats` (the `debug.render_stats` v1/v2 command)
/// returns for a single terminal panel's renderer/Metal/window state.
///
/// Every field is a primitive leaf the app-side witness fills from the panel's
/// `debugRenderStats()` reading; this value type owns the wire shape and the
/// `OK <json>` line assembly so the god file keeps only the live state reads.
/// The declared property order is the wire order: synthesized `Codable`
/// encodes in declaration order, so the emitted JSON is byte-identical to the
/// legacy app-side struct.
public struct RenderStatsResponse: Codable, Sendable {
    /// The terminal panel's surface id (uppercased UUID string).
    public let panelId: String
    /// The renderer's cumulative draw count.
    public let drawCount: Int
    /// The renderer's last draw timestamp.
    public let lastDrawTime: Double
    /// The Metal layer's cumulative drawable count.
    public let metalDrawableCount: Int
    /// The Metal layer's last drawable timestamp.
    public let metalLastDrawableTime: Double
    /// The Metal layer's cumulative present count.
    public let presentCount: Int
    /// The Metal layer's last present timestamp.
    public let lastPresentTime: Double
    /// The hosted layer's class name.
    public let layerClass: String
    /// The hosted layer's contents-key description.
    public let layerContentsKey: String
    /// Whether the hosted view is currently in a window.
    public let inWindow: Bool
    /// Whether that window is key.
    public let windowIsKey: Bool
    /// Whether that window is occlusion-visible.
    public let windowOcclusionVisible: Bool
    /// Whether the app is active.
    public let appIsActive: Bool
    /// Whether the surface is active.
    public let isActive: Bool
    /// Whether the surface desires focus.
    public let desiredFocus: Bool
    /// Whether the surface view is the first responder.
    public let isFirstResponder: Bool

    /// Creates a render-stats payload from already-read primitive leaves.
    ///
    /// - Parameters:
    ///   - panelId: The terminal panel's surface id (uppercased UUID string).
    ///   - drawCount: The renderer's cumulative draw count.
    ///   - lastDrawTime: The renderer's last draw timestamp.
    ///   - metalDrawableCount: The Metal layer's cumulative drawable count.
    ///   - metalLastDrawableTime: The Metal layer's last drawable timestamp.
    ///   - presentCount: The Metal layer's cumulative present count.
    ///   - lastPresentTime: The Metal layer's last present timestamp.
    ///   - layerClass: The hosted layer's class name.
    ///   - layerContentsKey: The hosted layer's contents-key description.
    ///   - inWindow: Whether the hosted view is currently in a window.
    ///   - windowIsKey: Whether that window is key.
    ///   - windowOcclusionVisible: Whether that window is occlusion-visible.
    ///   - appIsActive: Whether the app is active.
    ///   - isActive: Whether the surface is active.
    ///   - desiredFocus: Whether the surface desires focus.
    ///   - isFirstResponder: Whether the surface view is the first responder.
    public init(
        panelId: String,
        drawCount: Int,
        lastDrawTime: Double,
        metalDrawableCount: Int,
        metalLastDrawableTime: Double,
        presentCount: Int,
        lastPresentTime: Double,
        layerClass: String,
        layerContentsKey: String,
        inWindow: Bool,
        windowIsKey: Bool,
        windowOcclusionVisible: Bool,
        appIsActive: Bool,
        isActive: Bool,
        desiredFocus: Bool,
        isFirstResponder: Bool
    ) {
        self.panelId = panelId
        self.drawCount = drawCount
        self.lastDrawTime = lastDrawTime
        self.metalDrawableCount = metalDrawableCount
        self.metalLastDrawableTime = metalLastDrawableTime
        self.presentCount = presentCount
        self.lastPresentTime = lastPresentTime
        self.layerClass = layerClass
        self.layerContentsKey = layerContentsKey
        self.inWindow = inWindow
        self.windowIsKey = windowIsKey
        self.windowOcclusionVisible = windowOcclusionVisible
        self.appIsActive = appIsActive
        self.isActive = isActive
        self.desiredFocus = desiredFocus
        self.isFirstResponder = isFirstResponder
    }

    /// Encodes the payload as the `render_stats` `OK <json>` v1 response line,
    /// or `nil` when JSON encoding fails (the legacy
    /// `ERROR: Failed to encode render_stats` outcome the caller forms).
    public func okResponseLine() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "OK \(json)"
    }
}
#endif
