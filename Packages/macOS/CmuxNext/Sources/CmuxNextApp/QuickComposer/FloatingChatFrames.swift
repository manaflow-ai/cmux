import AppKit

/// Where the floating chat sits on each screen (cx-b9qi): the frame it was
/// last moved or resized to there, saved in user defaults by display.
struct FloatingChatFrames {
    static let key = "quickComposer.floatingChatFrames"
    /// A first floating chat: a narrow column, tall enough to read a turn.
    static let defaultSize = CGSize(width: 440, height: 620)
    static let minimumSize = CGSize(width: 320, height: 200)

    let defaults: UserDefaults

    /// The frame saved on display `id`, if any.
    func frame(onDisplay id: String) -> CGRect? {
        guard let saved = (defaults.dictionary(forKey: Self.key) as? [String: String])?[id] else { return nil }
        let frame = NSRectFromString(saved)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    func save(_ frame: CGRect, onDisplay id: String) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        all[id] = NSStringFromRect(frame)
        defaults.set(all, forKey: Self.key)
    }

    /// `saved`, kept inside `visible`; without one, the default size with its
    /// top at the composer's (`anchor`) and centered on it.
    static func placement(saved: CGRect?, near anchor: CGRect, in visible: CGRect) -> CGRect {
        var frame = saved ?? CGRect(x: anchor.midX - defaultSize.width / 2, y: anchor.maxY - defaultSize.height,
                                    width: defaultSize.width, height: defaultSize.height)
        frame.size.width = min(max(frame.width, minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, minimumSize.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width.rounded(), height: frame.height.rounded())
    }

    /// A screen's key: its display id.
    static func display(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return screen.localizedName }
        return String(number.uint32Value)
    }
}
