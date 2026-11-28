import CmuxNextDaemon
import CmuxNextSettings

/// What Cmd-T opens in a pane.
nonisolated enum NewTabKind: Equatable, Sendable {
    case terminal
    /// A browser tab on `engine` (nil: `browser.defaultEngine`).
    case browser(engine: String?)
    case agent
    /// The new tab page, to pick the kind.
    case page

    /// The pane's selected tab decides: a browser tab (daemon or
    /// session-local) gets a browser tab on its engine, so cookies and
    /// extensions stay in that engine; an agent tab gets an agent tab; a
    /// terminal, a remote terminal or an empty pane gets a terminal tab.
    static func resolve(selectedKind: TabKind?, engine: String?, isLocalBrowser: Bool, isAgent: Bool = false) -> NewTabKind {
        if isAgent { return .agent }
        if selectedKind == .browser { return .browser(engine: engine) }
        if isLocalBrowser { return .browser(engine: nil) }
        return .terminal
    }

    /// `tabs.newTabKind` over the same-kind rule. Auto takes the kind last
    /// opened in the focused tab's folder (else anywhere), and the same
    /// kind before anything was opened.
    /// The Terminal template (`tabs.newTabTemplate`) turns the page into a terminal.
    static func resolve(_ setting: NewTabDefaultKind, template: NewTabTemplate? = nil, sameKind: NewTabKind,
                        recent: NewTabKind?) -> NewTabKind {
        let kind = resolveKind(setting, sameKind: sameKind, recent: recent)
        return kind == .page && template == .terminal ? .terminal : kind
    }

    private static func resolveKind(_ setting: NewTabDefaultKind, sameKind: NewTabKind, recent: NewTabKind?) -> NewTabKind {
        switch setting {
        case .sameKind: sameKind
        case .terminal: .terminal
        case .browser: .browser(engine: nil)
        case .agent: .agent
        case .page: .page
        case .auto: recent ?? sameKind
        }
    }
}

/// What Auto remembers: the kind last opened on purpose (Cmd-T, a New
/// action, a new tab page choice) in each folder and overall. The new tab
/// page itself is a chooser, not a kind. Bounded to the most recent folders.
nonisolated struct NewTabKindMemory: Sendable {
    static let maximumFolders = 64
    private(set) var last: NewTabKind?
    private var byFolder: [String: NewTabKind] = [:]
    private var folders: [String] = []

    mutating func record(_ kind: NewTabKind, folder: String?) {
        guard kind != .page else { return }
        last = kind
        guard let folder else { return }
        byFolder[folder] = kind
        folders.removeAll { $0 == folder }
        folders.append(folder)
        if folders.count > Self.maximumFolders { byFolder[folders.removeFirst()] = nil }
    }

    func recent(in folder: String?) -> NewTabKind? {
        folder.flatMap { byFolder[$0] } ?? last
    }
}
