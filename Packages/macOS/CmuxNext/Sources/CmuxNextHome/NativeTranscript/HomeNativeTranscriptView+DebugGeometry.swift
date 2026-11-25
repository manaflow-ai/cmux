#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

extension HomeNativeTranscriptView {
    /// Read-only native approval geometry and state for capture automation.
    public func debugApprovalCards() -> [(id: String, text: String, pending: Bool, busy: Bool, ended: Bool, allow: CGRect, deny: CGRect)] {
        transcript.debugApprovalCards()
    }

    /// The typing bubble in window points (bottom-left origin), for home-typing-still.py.
    public func debugTypingState() -> [String: Any] {
        guard let rect = debugTypingBubbleFrame(), let size = window?.frame.size else {
            return ["ok": false, "error": "no typing row shows"]
        }
        var result = Self.debugBox(rect).mapValues { $0 as Any }
        result.merge(["ok": true, "windowWidth": Double(size.width), "windowHeight": Double(size.height),
                      "hostX": Double(debugHostOrigin.x), "hostY": Double(debugHostOrigin.y)]) { _, new in new }
        return result
    }

    /// Visible rows in window points, top to bottom: home-typing-still.py and home-hidden-messages.py.
    public func debugRowsState() -> [String: Any] {
        guard let size = window?.frame.size else { return ["ok": false, "error": "no window"] }
        let rows: [[String: Any]] = debugRowFrames().map { row in
            var result = Self.debugBox(row.frame).mapValues { $0 as Any }
            result.merge(["kind": row.kind, "key": row.key, "outgoing": row.outgoing,
                          "balloon": Self.debugBox(row.balloon)]) { _, new in new }
            return result
        }
        return ["ok": !rows.isEmpty, "rows": rows, "windowWidth": Double(size.width),
                "scale": Double(window?.backingScaleFactor ?? 0), "trim": Double(debugTranscriptWidthTrim),
                "hostRight": Double(debugHostFrame.maxX), "windowHeight": Double(size.height),
                "hostX": Double(debugHostOrigin.x), "hostY": Double(debugHostOrigin.y)]
    }

    static func debugBox(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}
#endif
