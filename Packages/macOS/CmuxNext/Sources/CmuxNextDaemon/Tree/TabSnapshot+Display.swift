import Foundation

// TabSnapshot is generated from cmux-tui/spec/sdk-schema.json (swift_app/bindings.json, family Tree).
extension TabSnapshot {
    /// Title a tab strip shows: the user name wins over the program title.
    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }

    /// True when the app draws this tab itself; `attach-surface` refuses it.
    public var isFrontendOwned: Bool {
        browserRenderer == "frontend" || kind == .remoteTerminal || kind == .conversation
    }
}
