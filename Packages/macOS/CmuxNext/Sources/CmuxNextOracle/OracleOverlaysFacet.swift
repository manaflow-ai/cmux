#if DEBUG || CMUX_BENCH_HOOKS
/// The `overlays` facet (p15-oracle-038, schemas/oracle/snapshot-v1.schema.json `overlays`): the layers above each
/// window's content, the palette, the dialog, the hover card and the find bar. The host reads them from the
/// controllers that own them (never a view tree) in the snapshot's main-actor turn; this type gives them the
/// schema's shape. Chromium's UI tests read the same from their owners: omnibox matches from
/// `AutocompleteController::result()` (components/omnibox/browser/autocomplete_controller.h), the find bar from
/// `FindTabHelper::find_result()` (components/find_in_page/find_tab_helper.h). Typed text goes in only as the
/// injected hash (`sha256:<hex>`).
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
        /// Bottom to top.
        public var stack: [Layer]
        public var palette: Palette
        /// The newest visible dialog's spec id.
        public var dialogSpecID: String?
        /// The shown hover card's item id (``OracleOverlaysFacet/itemID(ofHoverTarget:workspaceID:)``).
        public var hoverCardTarget: String?
        public var findBar: FindBar

        public init(stack: [Layer] = [], palette: Palette = Palette(), dialogSpecID: String? = nil, hoverCardTarget: String? = nil,
                    findBar: FindBar = FindBar()) {
            self.stack = stack
            self.palette = palette
            self.dialogSpecID = dialogSpecID
            self.hoverCardTarget = hoverCardTarget
            self.findBar = findBar
        }

        /// The facet's object; `hash` turns typed text into `sha256:<hex>`, and empty text is null.
        public func value(hash: (String) -> String) -> OracleValue {
            func text(_ value: String?) -> OracleValue { value.map(OracleValue.string) ?? .null }
            func index(_ value: Int?) -> OracleValue { value.map { OracleValue($0) } ?? .null }
            func typed(_ value: String) -> OracleValue { value.isEmpty ? .null : .string(hash(value)) }
            return [
                "stack": .array(stack.map { layer -> OracleValue in ["kind": .string(layer.kind.rawValue), "window": text(layer.window)] }),
                "palette": [
                    "open": .bool(palette.open),
                    "mode": text(palette.mode),
                    "querySha256": typed(palette.query),
                    "topIds": .array(palette.rowIDs.prefix(OracleOverlaysFacet.topCount).map(OracleValue.string)),
                    "selectedIndex": index(palette.selectedIndex),
                ],
                "dialog": ["specId": text(dialogSpecID)],
                "hoverCard": ["target": text(hoverCardTarget)],
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

    /// - Parameters:
    ///   - hash: `sha256:<hex>` of typed text.
    ///   - read: The overlays now; nil when the process has no windows' owner (not started), which answers
    ///     not-comparable.
    public init(hash: @escaping @Sendable (String) -> String, read: @escaping @MainActor @Sendable () -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = read() else {
                return .notComparable(reason: "no overlay owners in this process", task: OracleFacet.overlays.task)
            }
            return reading.value(hash: hash)
        }
    }

    /// The item a hover target id names: a workspace row or rail icon (`ws:`, `rail:`; its public id through
    /// `workspaceID`), a tab (`tab:`) or a workspace group (`grp:`). Nil for a card that is not an item's: a link
    /// chip's target holds its URL, which is private text.
    public static func itemID(ofHoverTarget raw: String, workspaceID: (String) -> String) -> String? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let rest = String(raw[raw.index(after: colon)...])
        guard !rest.isEmpty else { return nil }
        switch raw[..<colon] {
        case "ws", "rail": return workspaceID(rest)
        case "tab", "grp": return rest
        default: return nil
        }
    }
}
#endif
