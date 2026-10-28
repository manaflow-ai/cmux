#if DEBUG || CMUX_BENCH_HOOKS
/// The `windows` facet (schemas/oracle/snapshot-v1.schema.json `facets.windows`): the app's
/// windows front to back, the key and main window, and each window's full-screen, miniaturized and visible
/// state, its screen and its frame as fractions of that screen at 2 dp. Fractions, never points, so the same
/// case gives the same value on a laptop and on a fleet mini's display.
///
/// Chrome keeps the same facts per browser window: `BrowserList` orders windows by activation
/// (chrome/browser/ui/browser_list.h, `begin_browsers_ordered_by_activation`), and the `chrome.windows` API
/// reports `focused`, `state` (normal, minimized, fullscreen) and bounds per window
/// (chrome/browser/extensions/api/tabs/windows_util.cc). The host reads AppKit's windows in the snapshot's
/// main-actor turn; this type only gives them the schema's shape.
public struct OracleWindowsFacet: OracleFacetProvider {
    /// A rectangle in AppKit screen points, origin bottom left.
    public struct Rect: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }

        /// The area this rectangle shares with `other`, 0 when they do not overlap.
        func overlap(_ other: Rect) -> Double {
            max(0, min(maxX, other.maxX) - max(x, other.x)) * max(0, min(maxY, other.maxY) - max(y, other.y))
        }
    }

    /// One display: its full frame and the part windows lay out in (no menu bar, no Dock).
    public struct Screen: Sendable, Hashable {
        public var frame: Rect
        public var visibleFrame: Rect

        public init(frame: Rect, visibleFrame: Rect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// One window as AppKit reports it.
    public struct Window: Sendable, Hashable {
        /// The public window id (`win_…`), as `snapshot.get` prints it.
        public var id: String
        public var frame: Rect
        /// The index in ``Reading/screens`` of the screen AppKit puts the window on; nil when AppKit names
        /// none (the window is entirely off every screen).
        public var screen: Int?
        public var fullscreen: Bool
        public var miniaturized: Bool
        public var visible: Bool

        public init(id: String, frame: Rect, screen: Int?, fullscreen: Bool, miniaturized: Bool, visible: Bool) {
            self.id = id
            self.frame = frame
            self.screen = screen
            self.fullscreen = fullscreen
            self.miniaturized = miniaturized
            self.visible = visible
        }
    }

    /// The windows read in the snapshot's main-actor turn.
    public struct Reading: Sendable, Hashable {
        /// `NSScreen.screens`, in that order.
        public var screens: [Screen]
        /// Front to back.
        public var windows: [Window]
        public var key: String?
        public var main: String?

        public init(screens: [Screen], windows: [Window], key: String?, main: String?) {
            self.screens = screens
            self.windows = windows
            self.key = key
            self.main = main
        }

        /// The facet's object. Throws when a window is on no screen (AppKit names none and it overlaps none):
        /// the snapshot fails naming it rather than recording a screen and a frame nobody measured.
        public func value() throws(OracleFacetError) -> OracleValue {
            var list: [OracleValue] = []
            for window in windows {
                guard let index = screenIndex(of: window) else {
                    throw OracleFacetError("window \(window.id) is on no screen to measure its frame against")
                }
                let frame = try OracleWindowsFacet.fractions(of: window, on: screens[index])
                list.append([
                    "id": .string(window.id),
                    "fullscreen": .bool(window.fullscreen),
                    "miniaturized": .bool(window.miniaturized),
                    "visible": .bool(window.visible),
                    "screen": OracleValue(index),
                    "frame": frame,
                ])
            }
            return [
                "count": OracleValue(windows.count),
                "order": .array(windows.map { .string($0.id) }),
                "key": key.map(OracleValue.string) ?? .null,
                "main": main.map(OracleValue.string) ?? .null,
                "list": .array(list),
            ]
        }

        /// AppKit's screen for the window, else the screen that holds most of its frame; nil when it overlaps
        /// no screen.
        public func screenIndex(of window: Window) -> Int? {
            if let index = window.screen, screens.indices.contains(index) { return index }
            var best: (index: Int, area: Double)?
            for (index, screen) in screens.enumerated() {
                let area = screen.frame.overlap(window.frame)
                if area > (best?.area ?? 0) { best = (index, area) }
            }
            return best?.index
        }
    }

    public var facet: OracleFacet { .windows }
    public let capture: OracleFacetCapture

    /// - Parameter read: Reads the windows now, in the snapshot's main-actor turn. A `debug.oracle.wait_for` on
    ///   the facet wakes on each change of what `read` observes and on each control snapshot publish, so `read`
    ///   must also observe a value that changes with each AppKit window change (frame, full screen, miniaturize,
    ///   key and main, screens): AppKit's state is not observable, and a wait on a frame or on full screen would
    ///   otherwise read once and end as a false Timeout.
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> Reading) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            try read().value()
        }
    }

    /// The window's frame as fractions of its screen at 2 dp, origin top left: `x` and `y` from the screen's
    /// left and top edges, `width` and `height` of the screen's. A window in full screen measures against the
    /// whole screen (it covers the menu bar), any other against the visible frame windows lay out in.
    public static func fractions(of window: Window, on screen: Screen) throws(OracleFacetError) -> OracleValue {
        let base = window.fullscreen ? screen.frame : screen.visibleFrame
        guard base.width > 0, base.height > 0 else {
            throw OracleFacetError("window \(window.id) is on a screen with an empty frame")
        }
        let frame = window.frame
        return [
            "x": .number(rounded((frame.x - base.x) / base.width)),
            "y": .number(rounded((base.maxY - frame.maxY) / base.height)),
            "width": .number(rounded(frame.width / base.width)),
            "height": .number(rounded(frame.height / base.height)),
        ]
    }

    /// `value` at 2 dp (the schema's `x-oracle-precision` 0.01), with no negative zero.
    public static func rounded(_ value: Double) -> Double {
        let result = (value * 100).rounded() / 100
        return result == 0 ? 0 : result
    }
}
#endif
