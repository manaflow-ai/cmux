import Foundation

/// Internal pages: cmux's own surfaces (Settings, Debug Settings, the App
/// Store) shown as tabs in a pane instead of windows of their own.
///
/// One mechanism for every page (plans/cmux-next/COORDINATION.md, lane 20):
/// - a session-local tab kind, ids `local-page:<page>:<uuid>`
///   (``LocalPageTab``), kept by ``InternalPageTabStore`` like agent tabs
///   (not restored after relaunch);
/// - a page registers one ``InternalPageProvider`` (`services.pages.register`);
/// - its catalog show action (`openSettings`, `openDebugSettings`,
///   `appStore.show`) calls `services.pages.show(<page>)`, which selects the
///   page's tab in the active window or opens one after the focused pane's
///   selected tab. One tab per page per window.
package nonisolated struct InternalPageID: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }

    package static let settings = InternalPageID(rawValue: "settings")
    package static let debugSettings = InternalPageID(rawValue: "debug-settings")
    /// The Automations page (docs/automations-platonic-ideal.md section 8): `automations.show`, the sidebar item.
    package static let automations = InternalPageID(rawValue: "automations")
}

/// Ids of internal page tabs.
package nonisolated struct LocalPageTab {
    package nonisolated init() {}
    package static let prefix = "local-page:"

    package static func makeKey(_ page: InternalPageID) -> String {
        prefix + page.rawValue + ":" + UUID().uuidString.lowercased()
    }

    /// The page a tab id shows, or nil for another kind of tab.
    package static func page(of key: String) -> InternalPageID? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.lastIndex(of: ":"), colon > rest.startIndex else { return nil }
        return InternalPageID(rawValue: String(rest[..<colon]))
    }
}
