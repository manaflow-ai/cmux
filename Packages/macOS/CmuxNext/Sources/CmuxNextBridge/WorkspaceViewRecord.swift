public import CmuxNextLayout
public import CoreGraphics

/// What a workspace's views showed that the daemon does not keep: each screen's strip, row and
/// scroll area offsets, each pane's selected tab and tab strip scroll, the focused pane and the
/// screen bar's scroll. Its window saves it when it unmounts the workspace
/// (`WindowController.releaseParked`) and the next mount applies it before its first frame commits
/// (p07-memory-033), so an unmount loses nothing the person can see. The tree, tabs and titles come
/// back from the daemon's store.
///
/// Chrome keeps the same for a discarded tab: the `NavigationEntry`'s `PageState` holds the scroll
/// offset and form state (content/public/browser/navigation_entry.h), and the reloaded renderer
/// restores them from its `HistoryItem` view state before the first paint
/// (third_party/blink/renderer/core/loader/history_item.h). About 1 KB for 12 panes; at most 2 KB.
public nonisolated struct WorkspaceViewRecord: Hashable, Codable, Sendable {
    public nonisolated struct Screen: Hashable, Codable, Sendable {
        /// The column strip's offset; nil on a split screen.
        public var strip: Double?
        /// Each overflowing row column's vertical offset, by column id.
        public var rows: [String: Double]
        /// Each scroll area's offset, by split id.
        public var areas: [String: Double]

        public init(strip: Double? = nil, rows: [String: Double] = [:], areas: [String: Double] = [:]) {
            self.strip = strip
            self.rows = rows
            self.areas = areas
        }

        private enum CodingKeys: String, CodingKey {
            case strip = "s", rows = "r", areas = "a"
        }
    }

    public nonisolated struct Pane: Hashable, Codable, Sendable {
        /// The selected tab.
        public var tab: String?
        /// The tab strip's scroll; nil at its start.
        public var strip: Double?

        public init(tab: String? = nil, strip: Double? = nil) {
            self.tab = tab
            self.strip = strip
        }

        private enum CodingKeys: String, CodingKey {
            case tab = "t", strip = "s"
        }
    }

    /// By screen id.
    public var screens: [String: Screen]
    /// By pane key.
    public var panes: [String: Pane]
    public var focusedPane: String?
    /// The screen bar's scroll; nil at its start.
    public var screenBar: Double?

    public init(screens: [String: Screen] = [:], panes: [String: Pane] = [:], focusedPane: String? = nil, screenBar: Double? = nil) {
        self.screens = screens
        self.panes = panes
        self.focusedPane = focusedPane
        self.screenBar = screenBar
    }

    private enum CodingKeys: String, CodingKey {
        case screens = "c", panes = "p", focusedPane = "f", screenBar = "b"
    }

    /// The record of a strip offset: nil at the start (the strip's own default), so a record of
    /// panes nobody scrolled stays small.
    public static func stripOffset(_ offset: CGFloat) -> Double? {
        offset > 0.5 ? Double(offset) : nil
    }
}

public nonisolated extension WorkspaceViewRecord.Screen {
    init(_ scroll: LayoutScreenScroll) {
        self.init(strip: scroll.strip.map { Double($0) },
                  rows: Dictionary(uniqueKeysWithValues: scroll.rows.map { ($0.key.rawValue, Double($0.value)) }),
                  areas: Dictionary(uniqueKeysWithValues: scroll.areas.map { ($0.key.rawValue, Double($0.value)) }))
    }

    var layoutScroll: LayoutScreenScroll {
        LayoutScreenScroll(strip: strip.map { CGFloat($0) },
                           rows: Dictionary(uniqueKeysWithValues: rows.map { (CmuxNextLayout.ColumnID($0.key), CGFloat($0.value)) }),
                           areas: Dictionary(uniqueKeysWithValues: areas.map { (CmuxNextLayout.SplitID($0.key), CGFloat($0.value)) }))
    }
}
