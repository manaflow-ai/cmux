import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// A tab's second line and page marks in the workspace hover card (u9696), mapped with its row.
extension SidebarMapping {
    /// What a tab's row says under its title: the program's own status words (OSC 7501), else a
    /// page's host, a chat's agent, a terminal's folder (`shorten`ed as the row's folder is).
    static func tabDetail(_ tab: TabModel, shorten: (String) -> String) -> String? {
        if let words = StatusMapping.shared.detail(tab) { return words }
        switch tab.kind {
        case .browser:
            return tab.url.flatMap(host)
        case .conversation:
            return tab.agentName
        default:
            return tab.cwd.flatMap { $0.isEmpty ? nil : shorten($0) }
        }
    }

    /// A page address's host without a leading `www.`; nil for an address without one
    /// (the New Tab and blank pages, `file:`).
    static func host(_ address: String) -> String? {
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A page's sound and sleep as the hover card marks them.
    static func tabFlags(_ face: PageFace?) -> SidebarTabFlags {
        guard let face else { return [] }
        var flags: SidebarTabFlags = []
        switch face.audio {
        case .playing?: flags.insert(.playing)
        case .muted?: flags.insert(.muted)
        case nil: break
        }
        if face.hibernated { flags.insert(.hibernated) }
        return flags
    }
}
