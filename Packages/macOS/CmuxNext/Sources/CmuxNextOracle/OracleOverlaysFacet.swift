#if DEBUG || CMUX_BENCH_HOOKS
/// The `overlays` facet: the layers above each
/// window's content, the palette, the dialog, the hover card and the find bar. The host reads them from the
/// controllers that own them (never a view tree) in the snapshot's main-actor turn; this type orders them into the
/// stack and gives them the schema's shape. Chromium's UI tests read the same from their owners: omnibox matches
/// from `AutocompleteController::result()` (components/omnibox/browser/autocomplete_controller.h), the find bar
/// from `FindTabHelper::find_result()` (components/find_in_page/find_tab_helper.h). Typed text and any private
/// part of a palette row id go in only as the injected hash (`sha256:<hex>`).
public struct OracleOverlaysFacet: OracleFacetProvider {
    /// At most this many palette rows go in `topIds`.
    public static let topCount = 10

    /// A layer of the stack: the schema's `stack[*].kind`.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case palette, dialog, hoverCard, findBar, popover, menu, sheet, toast, refusalHud
    }

    public struct Layer: Sendable, Hashable {
        public var kind: Kind
        /// The window's public id (`win_<hex>`), nil for a layer no cmux window owns.
        public var window: String?

        public init(_ kind: Kind, window: String?) {
            self.kind = kind
            self.window = window
        }
    }

    /// An overlay on a window's overlay host and the name its presenter gave it (a dialog's spec id).
    public struct Hosted: Sendable, Hashable {
        public var kind: Kind
        public var name: String?

        public init(_ kind: Kind, name: String? = nil) {
            self.kind = kind
            self.name = name
        }
    }

    /// One window's layers as their owners hold them, each source bottom to top. The sources draw in separate
    /// places of the window, so their order in the stack is fixed: find bars are inside the content, under every
    /// overlay; the overlay host's panel is a child window above the window's pages; the focus model's panels
    /// (the palette at the floating level, a sheet, the group editor, rename) are windows above that panel, in
    /// the order they opened; the hover card's panel is added above them.
    public struct WindowLayers: Sendable, Hashable {
        /// The window's public id; nil for the layers no cmux window owns (the app host, a palette or card over
        /// no cmux window).
        public var window: String?
        /// Find bars shown in the window's panes.
        public var findBars: Int
        /// The overlay host's layers, bottom to top.
        public var hosted: [Hosted]
        /// The focus model's overlays in open order.
        public var panels: [Kind]
        public var hoverCard: Bool

        public init(window: String?, findBars: Int = 0, hosted: [Hosted] = [], panels: [Kind] = [], hoverCard: Bool = false) {
            self.window = window
            self.findBars = findBars
            self.hosted = hosted
            self.panels = panels
            self.hoverCard = hoverCard
        }

        /// The window's part of the stack, bottom to top.
        public var layers: [Layer] {
            let kinds = Array(repeating: Kind.findBar, count: findBars) + hosted.map(\.kind) + panels + (hoverCard ? [.hoverCard] : [])
            return kinds.map { Layer($0, window: window) }
        }
    }

    /// The item a shown hover card is about, as its owner parsed it from the card's target: a workspace row or
    /// rail mark (the workspace's public id), a workspace group, or a tab.
    public enum HoverTarget: Sendable, Hashable {
        case workspace(String)
        case group(String)
        case tab(String)

        public var id: String {
            switch self {
            case .workspace(let id), .group(let id), .tab(let id): id
            }
        }
    }

    public struct Palette: Sendable, Hashable {
        public var open: Bool
        /// The shown page's id, nil on a text page or while closed.
        public var mode: String?
        public var query: String
        /// Row ids in display order; the facet keeps the first ``OracleOverlaysFacet/topCount``.
        public var rowIDs: [String]
        /// The selected row's index among all rows.
        public var selectedIndex: Int?

        public init(open: Bool = false, mode: String? = nil, query: String = "", rowIDs: [String] = [], selectedIndex: Int? = nil) {
            self.open = open
            self.mode = mode
            self.query = query
            self.rowIDs = rowIDs
            self.selectedIndex = selectedIndex
        }
    }

    public struct FindBar: Sendable, Hashable {
        public var open: Bool
        /// The focused pane's daemon id when it shows a find bar's content.
        public var pane: String?
        /// Kept after the bar closes (reopening searches it again).
        public var query: String
        public var matches: Int
        /// The selected match's 0-based index.
        public var selected: Int?

        public init(open: Bool = false, pane: String? = nil, query: String = "", matches: Int = 0, selected: Int? = nil) {
            self.open = open
            self.pane = pane
            self.query = query
            self.matches = matches
            self.selected = selected
        }
    }

    /// What the host read.
    public struct Reading: Sendable, Hashable {
        /// Bottom to top: each window's layers in the window manager's order, then the layers no window owns.
        public var stack: [Layer]
        public var palette: Palette
        /// The spec id of the topmost dialog on the stack (nil when it has none, or no dialog shows).
        public var dialogSpecID: String?
        public var hoverCard: HoverTarget?
        public var findBar: FindBar

        public init(windows: [WindowLayers] = [], palette: Palette = Palette(), hoverCard: HoverTarget? = nil, findBar: FindBar = FindBar()) {
            stack = windows.flatMap(\.layers)
            dialogSpecID = windows.flatMap(\.hosted).last { $0.kind == .dialog }?.name
            self.palette = palette
            self.hoverCard = hoverCard
            self.findBar = findBar
        }

        /// The facet's object; `hash` turns typed text into `sha256:<hex>`, and empty text is null.
        public func value(hash: (String) -> String) -> OracleValue {
            func text(_ value: String?) -> OracleValue { value.map(OracleValue.string) ?? .null }
            func index(_ value: Int?) -> OracleValue { value.map { OracleValue($0) } ?? .null }
            func typed(_ value: String) -> OracleValue { value.isEmpty ? .null : .string(hash(value)) }
            let topIDs = palette.rowIDs.prefix(OracleOverlaysFacet.topCount).map { OracleOverlaysFacet.stableRowID($0, hash: hash) }
            return [
                "stack": .array(stack.map { layer -> OracleValue in ["kind": .string(layer.kind.rawValue), "window": text(layer.window)] }),
                "palette": [
                    "open": .bool(palette.open),
                    "mode": text(palette.mode),
                    "querySha256": typed(palette.query),
                    "topIds": .array(topIDs.map(OracleValue.string)),
                    "selectedIndex": index(palette.selectedIndex),
                ],
                "dialog": ["specId": text(dialogSpecID)],
                "hoverCard": ["target": text(hoverCard?.id)],
                "findBar": [
                    "open": .bool(findBar.open),
                    "pane": text(findBar.pane),
                    "querySha256": typed(findBar.query),
                    "matches": OracleValue(findBar.matches),
                    "selected": index(findBar.selected),
                ],
            ]
        }
    }

    public var facet: OracleFacet { .overlays }
    public let capture: OracleFacetCapture
    public let changes: OracleFacetChanges?

    /// - Parameters:
    ///   - hash: `sha256:<hex>` of typed text.
    ///   - changes: The owners' change signal (an overlay presented or dismissed, a hover card shown or hidden, a
    ///     focus overlay opened or closed): most of what the read touches is not observable, so a wait needs it.
    ///   - read: The overlays now; nil when the process has no windows' owner (not started), which answers
    ///     not-comparable.
    public init(hash: @escaping @Sendable (String) -> String, changes: OracleFacetChanges? = nil,
                read: @escaping @MainActor @Sendable () -> Reading?) {
        self.changes = changes
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = read() else {
                return .notComparable(reason: "no overlay owners in this process", task: OracleFacet.overlays.task)
            }
            return reading.value(hash: hash)
        }
    }

    /// A palette row id as `topIds` holds it: the same on every run and machine, with no private text. The kind
    /// before the first `:` stays; a payload that is not an opaque token (letters, digits, `.`, `_`, `-`, `:`),
    /// such as a folder's path, a URL or a name, goes in as its hash: `path:/Users/me/src` is `path:sha256:<hex>`.
    public static func stableRowID(_ id: String, hash: (String) -> String) -> String {
        func isOpaque(_ text: Substring) -> Bool {
            text.unicodeScalars.allSatisfy { scalar in
                switch scalar {
                case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-", ":": true
                default: false
                }
            }
        }
        guard let colon = id.firstIndex(of: ":") else { return isOpaque(id[...]) ? id : hash(id) }
        let payload = id[id.index(after: colon)...]
        guard !isOpaque(payload) else { return id }
        return String(id[...colon]) + hash(String(payload))
    }
}
#endif
