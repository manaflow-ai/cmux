package import CmuxNextSettings
package import Foundation

/// When hidden content may be discarded: Chrome's proactive discard of a background tab after a
/// time hidden (chrome/browser/performance_manager/policies/proactive_discarding_policy.cc). Memory
/// pressure lets `afterHidden` content go sooner (``DiscardReason/urgent``); `never` keeps it
/// until it closes. Each kind or page declares its own; ``standard`` is the one of content that
/// declares none.
package nonisolated enum ContentDiscardPolicy: Hashable, Sendable {
    case never
    case afterHidden(Duration)

    /// Ten minutes hidden.
    package static let standard = ContentDiscardPolicy.afterHidden(.seconds(600))

    /// Seconds hidden before the content is due; nil when it never is.
    package var timeout: Double? {
        guard case .afterHidden(let duration) = self else { return nil }
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// What discarded content showed besides its address or route, kept while it is gone and given
/// back when it is made again (Chrome keeps a discarded tab's navigation entries with their scroll
/// and form state, content/public/browser/navigation_entry.h).
package nonisolated struct ContentViewState: Hashable, Sendable {
    /// The document's visible origin.
    package var scroll: CGPoint?
    /// The text of its search or filter field.
    package var search: String?
    /// What it had selected (an item id, a row).
    package var selection: String?
    /// Any other value it keeps, by its own names.
    package var values: [String: String]

    package init(scroll: CGPoint? = nil, search: String? = nil, selection: String? = nil, values: [String: String] = [:]) {
        self.scroll = scroll
        self.search = search
        self.selection = selection
        self.values = values
    }
}

// A web page's own state across a discard: its answer to its `viewState` op (a file page's mode,
// anchor and history, the diff's anchored file, the Files tree's open folders) as the `page` value.
// The discard record is its only copy, so a state always comes from the discard that saved it, as
// Chrome keeps a discarded tab's state on its navigation entry: a discard nobody prepared (the
// person's Hibernate Tab) or a page that did not answer brings back none.
nonisolated extension ContentViewState {
    package static let pageKey = "page"

    /// The state of a page that answered `answer` to its `viewState` op.
    package init(page answer: JSONValue) {
        self.init(values: [Self.pageKey: answer.compactText])
    }

    /// The page's `viewState` answer; nil when it gave none.
    package var page: JSONValue? {
        values[Self.pageKey].flatMap { try? JSONValue.parse(Data($0.utf8)) }
    }
}
