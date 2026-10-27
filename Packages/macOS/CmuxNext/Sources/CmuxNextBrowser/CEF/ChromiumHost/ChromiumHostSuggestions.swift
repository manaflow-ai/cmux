import CmuxNextCompat
import Foundation

/// A field's autofill, password or `<datalist>` suggestions as the Chromium Host sends them (the
/// SHOW of CMUX_SHIM_SUGGESTIONS; fork API 31's suggestion handler, tasks 172 and 061 of
/// plans/cmux-next/chrome-parity/p01-process.md). Chrome's `AutofillPopupController` gives its view
/// the same: the rows, the field's bounds and its text direction
/// (components/autofill/core/browser/ui/autofill_popup_delegate.h, `AutofillSuggestionController`),
/// and the view only draws them and reports the person's choices.
nonisolated struct ChromiumHostSuggestions: Equatable, Sendable {
    /// One row, as Chrome's `Suggestion` reaches its popup view.
    struct Row: Equatable, Sendable {
        /// The fork's `CMUX_SUGGESTION_ROW_*`.
        enum Kind: Int, Sendable {
            /// An address, card, password, autocomplete or `<datalist>` entry.
            case entry = 0
            /// A line between groups; never selected.
            case separator = 1
            /// A group heading; never accepted.
            case title = 2
            /// "Manage addresses…", "Manage passwords…": below the entries, after a separator.
            case footer = 3
        }

        var kind: Kind
        /// Chromium's `autofill::SuggestionType` (components/autofill/core/browser/suggestions/suggestion_type.h).
        var type: Int
        var main: String
        /// The minor texts after the main text.
        var minor: String
        /// The label lines below the main text.
        var labels: [String]
        /// What VoiceOver reads; "" when the texts say it.
        var voiceOver: String
        var selectable: Bool
        var acceptable: Bool
        /// A placeholder while Chromium loads the row's value.
        var loading: Bool

        /// `SuggestionType::kAutocompleteEntry`: the one type whose row has a delete button in Chrome's
        /// popup (`PopupRowView`'s delete button, chrome/browser/ui/views/autofill/popup/popup_row_view.cc).
        static let autocompleteEntry = 0

        /// The row has Chrome's delete button.
        var removable: Bool { kind == .entry && type == Self.autocompleteEntry && !loading }

        /// What the row says to VoiceOver: the fork's text, else its texts.
        var accessibilityLabel: String {
            voiceOver.isEmpty ? ([main, minor] + labels).filter { !$0.isEmpty }.joined(separator: ", ") : voiceOver
        }
    }

    /// Unique in the host; every show has a new one (indices change with the rows).
    var token: Int64
    /// The field the rows belong to, in the page view's DIP from its top left.
    var field: CGRect
    /// The field's text runs right to left: Chrome aligns its popup with the field's trailing edge.
    var rightToLeft: Bool
    /// The row a key selected, nil for none.
    var selected: Int?
    var rows: [Row]

    /// The SHOW event's rows: `json` is the shim's (CEFShim/src/suggestion_rows.h, `SuggestionsJSON`).
    /// Nil for JSON the shim never writes.
    init?(token: Int64, json: String) {
        guard let data = json.data(using: .utf8), let wire = try? JSONDecoder().blockingDecode(Wire.self, from: data) else { return nil }
        self.token = token
        field = CGRect(x: wire.x, y: wire.y, width: max(0, wire.width), height: max(0, wire.height))
        rightToLeft = wire.rtl
        rows = wire.rows.map { row in
            Row(kind: Row.Kind(rawValue: row.kind) ?? .entry, type: row.type, main: row.main, minor: row.minor,
                labels: row.label.isEmpty ? [] : row.label.components(separatedBy: "\n"), voiceOver: row.voiceOver,
                selectable: row.selectable, acceptable: row.acceptable, loading: row.loading)
        }
        selected = rows.indices.contains(wire.selected) ? wire.selected : nil
    }

    init(token: Int64, field: CGRect, rightToLeft: Bool = false, selected: Int? = nil, rows: [Row]) {
        self.token = token
        self.field = field
        self.rightToLeft = rightToLeft
        self.selected = selected
        self.rows = rows
    }

    /// The shim's JSON.
    private struct Wire: Decodable {
        struct WireRow: Decodable {
            let kind: Int
            let type: Int
            let main: String
            let minor: String
            let label: String
            let voiceOver: String
            let selectable: Bool
            let acceptable: Bool
            let loading: Bool

            enum CodingKeys: String, CodingKey {
                case kind, type, main, minor, label, selectable, acceptable, loading
                case voiceOver = "voice_over"
            }
        }

        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let rtl: Bool
        let selected: Int
        let rows: [WireRow]
    }
}

/// One CMUX_SHIM_SUGGESTIONS event (`cmux_shim_suggestion_event_t`), for the page view of the browser
/// it names (``CEFPageViewEvent/suggestions(_:)``).
nonisolated enum ChromiumHostSuggestionEvent: Equatable, Sendable {
    /// New rows, or the shown rows replaced (a new token).
    case show(ChromiumHostSuggestions)
    /// A key in the field moved the selection of `token` to `row` (nil: none).
    case select(token: Int64, row: Int?)
    /// The rows of `token` closed (accepted, dismissed, the field lost focus, the page hid).
    case hide(token: Int64)
    /// What VoiceOver should say ("Address filled").
    case announce(String)

    /// The event's fields: request = the sub-kind, a = the token, b = the selected row, s1 = the
    /// rows' JSON or the announcement. Nil for a sub-kind or JSON the shim never sends.
    init?(request: Int32, a: Int64, b: Int64, s1: String) {
        switch request {
        case 0:
            guard let suggestions = ChromiumHostSuggestions(token: a, json: s1) else { return nil }
            self = .show(suggestions)
        case 1: self = .select(token: a, row: b >= 0 ? Int(clamping: b) : nil)
        case 2: self = .hide(token: a)
        case 3: self = .announce(s1)
        default: return nil
        }
    }
}

/// `cmux_shim_suggestion_action_t`: what the list tells Chromium about its rows.
nonisolated enum ChromiumHostSuggestionAction: Int32, Sendable {
    /// The rows are on screen: Chrome's 500 ms guard against early clicks starts.
    case shown = 0
    /// The pointer is over a row (-1: off every row); Chrome previews its values.
    case select = 1
    /// A row was clicked.
    case accept = 2
    /// An autocomplete row's delete button was clicked.
    case remove = 3
    /// A click outside the rows.
    case dismiss = 4
}
