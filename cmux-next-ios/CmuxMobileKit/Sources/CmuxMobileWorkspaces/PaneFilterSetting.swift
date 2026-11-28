#if os(iOS)
import CmuxMobileLinkFFI
import CmuxMobileModel
import Foundation
import Observation

/// Which panes the tab overview shows (Leo, 2026-11-23: "a ... filtering mechanism for only agent
/// sessions, agent sessions/terminals, and ... browsers on their own honestly should be a ...
/// toggle"). One choice for every workspace, kept across launches. The rule is Rust's
/// (`pane_filter_apply`); this holds the choice and saves it.
///
/// The default is agent sessions and terminals with browsers shown. The filter can hide them
/// with its own toggle (Leo: "we tuck that ... in some kinda toggle").
@MainActor
@Observable
public final class PaneFilterSetting {
    public static let shared = PaneFilterSetting()
    static let key = "cmux.mobile.overview.paneFilter"

    @ObservationIgnored private let defaults: UserDefaults?

    public var filter: PaneFilter {
        didSet {
            guard filter != oldValue else { return }
            defaults?.set(paneFilterEncode(filter: filter), forKey: Self.key)
        }
    }

    /// `defaults` nil: kept in memory only (tests, galleries).
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        filter = defaults?.string(forKey: Self.key).map { paneFilterDecode(saved: $0) } ?? paneFilterDefault()
    }

    public var scope: PaneScope {
        get { filter.scope }
        set { filter.scope = newValue }
    }

    public var showsBrowsers: Bool {
        get { filter.showBrowsers }
        set { filter.showBrowsers = newValue }
    }

    /// The person changed the filter from the default.
    public var isChanged: Bool { filter != paneFilterDefault() }
}

extension PaneKind {
    /// A Mac tab's kind as the filter sorts it; nil (a phone-side tab, such as Screen Sharing) is
    /// a kind the filter never hides.
    init(_ kind: WorkspaceTab.Kind?) {
        switch kind {
        case .agent: self = .agent
        case .terminal: self = .terminal
        case .browser: self = .browser
        case .simulator: self = .simulator
        case nil: self = .other
        }
    }
}
#endif
