#if DEBUG
public import Foundation

/// Pure cmd-click point resolution for the terminal cmd-click XCUITest scenario.
///
/// `TerminalCmdClickUITestRecorder` (app target) computes the token-point
/// payload via ``TerminalCmdClickTokenGrid`` and, when running a command file,
/// resolves the hit / selection points to drive against the live surface. That
/// resolution is a pure function of the already-computed `tokenPointPayload`
/// `[String: Any]` map plus the terminal hosted-view bounds, so it lives here
/// as a value type: the app reads `terminalPanel.hostedView.bounds` (a
/// `CGRect`) and hands it in at construction, and no AppKit, Ghostty, or
/// live-state coupling crosses the seam.
///
/// The math reproduces the legacy inline `AppDelegate` helpers byte-for-byte:
/// the same `Double`/`NSNumber` coercion, the same `1`-floored bounds clamping,
/// the same `bounds.height - yFromTop` flip, the same `tokenColumnOffset`
/// `Int`-then-`NSNumber` precedence, and the same `tokenCellMetrics.cellWidth`
/// column stride. ``loadCommand(at:)`` is the matching JSON command loader.
public struct TerminalCmdClickPointResolver {
    /// The token-point payload computed by ``TerminalCmdClickTokenGrid``.
    public let tokenPointPayload: [String: Any]?
    /// The terminal hosted-view bounds used for clamping and the y-flip.
    public let bounds: CGRect

    /// Creates a resolver bound to one token-point payload and the live bounds.
    ///
    /// - Parameters:
    ///   - tokenPointPayload: The `[String: Any]` token-point map, or `nil`.
    ///   - bounds: The terminal hosted-view bounds (`hostedView.bounds`).
    public init(tokenPointPayload: [String: Any]?, bounds: CGRect) {
        self.tokenPointPayload = tokenPointPayload
        self.bounds = bounds
    }

    /// Coerces a payload value to `Double`, accepting `Double` and `NSNumber`.
    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    /// Resolves the bounds-clamped, y-flipped point stored under `key` in the
    /// token-point payload, or `nil` if it is absent.
    public func pointFromPayload(_ key: String) -> NSPoint? {
        guard let payload = tokenPointPayload?[key] as? [String: Any],
              let x = doubleValue(payload["x"]),
              let yFromTop = doubleValue(payload["y"]) else {
            return nil
        }

        let clampedX = min(max(CGFloat(x), 1), max(bounds.width - 1, 1))
        let clampedYFromTop = min(
            max(CGFloat(yFromTop), 1),
            max(bounds.height - 1, 1)
        )
        return NSPoint(
            x: clampedX,
            y: bounds.height - clampedYFromTop
        )
    }

    /// Resolves the point `offset` token cells right of the selection start,
    /// using the payload's `tokenCellMetrics.cellWidth` stride.
    public func pointForTokenColumnOffset(_ offset: Int) -> NSPoint? {
        guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal"),
              let tokenCellMetrics = tokenPointPayload?["tokenCellMetrics"] as? [String: Any],
              let cellWidth = doubleValue(tokenCellMetrics["cellWidth"]) else {
            return nil
        }

        let unclampedX = selectionStart.x + (CGFloat(offset) * CGFloat(cellWidth))
        let clampedX = min(max(unclampedX, 1), max(bounds.width - 1, 1))
        return NSPoint(x: clampedX, y: selectionStart.y)
    }

    /// Resolves a command's target point: a `tokenColumnOffset` (`Int` then
    /// `NSNumber`) if present, else the payload point under `defaultPayloadKey`.
    public func commandPoint(
        from command: [String: Any],
        defaultPayloadKey: String
    ) -> NSPoint? {
        if let tokenColumnOffset = command["tokenColumnOffset"] as? Int {
            return pointForTokenColumnOffset(tokenColumnOffset)
        }
        if let tokenColumnOffset = command["tokenColumnOffset"] as? NSNumber {
            return pointForTokenColumnOffset(tokenColumnOffset.intValue)
        }
        return pointFromPayload(defaultPayloadKey)
    }

    /// Loads the JSON command object at `path`, or `nil` if it is missing or not
    /// a `[String: Any]` object.
    public static func loadCommand(at path: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
#endif
