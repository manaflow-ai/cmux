import Foundation

/// A pane a split intent shows before the daemon has it (`split-client-keys-v1`). Its handle and
/// its tab's surface live far above the daemon's numeric ids, so neither can name a daemon
/// object; its public pane, tab and terminal ids are the client-minted ones the split request
/// sends, so the daemon's pane is recognized by its public id when it arrives.
public struct ProvisionalPane: Sendable, Hashable {
    /// Daemon pane handles count up from 1; provisional ones live far above them.
    private static let handleBase: UInt64 = 1 << 62
    /// The lowest stand-in handle: a pane handle at or above it is a stand-in.
    static let firstHandle: UInt64 = handleBase
    @MainActor private static var next: UInt64 = 0

    /// The provisional pane's handle in the store.
    public let handle: PaneID
    /// `pane_<32 hex>`, sent as the split's `pane_id`.
    public let paneID: String
    /// `tab_<32 hex>`, sent as the split's `tab_id`.
    public let tabID: String
    /// The new terminal's host id (UUIDv4, 32 hex), sent as `terminal_id`.
    public let terminalID: String
    /// The surface of its provisional tab.
    public let surface: SurfaceID
    /// The tab it shows when it is not a terminal: a conversation tab under a provisional id
    /// (`conversation-tab-split-v1`), which the daemon's tab replaces when its pane arrives
    /// (`ProvisionalTab.echoed`). Nil: a terminal tab under `tabID` and `terminalID`.
    public let tab: TabSnapshot?
    /// `split_<32 hex>`, sent as the split's `split_id` (`split-client-split-id-v1`): the public
    /// id of the split it shows under, which the daemon's split keeps, so the daemon's layout
    /// names the split already shown.
    public let splitID: String
    /// Set when the pane opens as a new scrolling column after the target's column (New Column,
    /// `new-pane-right`) instead of splitting the target.
    public private(set) var column: ProvisionalColumn?
    /// Set when the pane opens as a new row below the target's row (New Row, `new-row`).
    public private(set) var row: ProvisionalRow?

    /// A fresh provisional pane with new client-minted ids.
    @MainActor public init() {
        self.init(tab: nil)
    }

    /// A fresh provisional terminal pane that opens as a new column (New Column): `width` is its
    /// viewport fraction; `widths` and `treeWidth` are the width changes it brings
    /// (``ProvisionalColumn``); `left` opens it before the target's column (New Column Left).
    @MainActor public init(columnWidth width: Double, widths: [ColumnID: Double] = [:], treeWidth: Double? = nil, left: Bool = false) {
        self.init(tab: nil)
        column = ProvisionalColumn(paneHandle: handle, width: width, widths: widths, treeWidth: treeWidth, left: left)
    }

    /// A fresh provisional terminal pane that opens as a new row of `height` permille (New Row).
    @MainActor public init(rowHeight height: Int) {
        self.init(tab: nil)
        row = ProvisionalRow(paneHandle: handle, height: height)
    }

    /// A provisional pane holding `tab`, a new conversation tab (an agent chat or the New Tab page)
    /// that `new-conversation-tab {split}` creates (``ProvisionalTab/conversation(_:)``).
    @MainActor public init(holding tab: TabSnapshot) {
        self.init(tab: tab)
    }

    @MainActor private init(tab: TabSnapshot?) {
        Self.next += 1
        handle = PaneID(rawValue: Self.handleBase + Self.next)
        surface = tab?.surface ?? ProvisionalTab().surface
        let hex = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        paneID = "pane_" + hex()
        tabID = "tab_" + hex()
        terminalID = hex()
        splitID = "split_" + hex()
        self.tab = tab
    }
}
