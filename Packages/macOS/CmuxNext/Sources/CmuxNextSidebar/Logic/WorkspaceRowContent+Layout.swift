import CmuxNextDesign
import Foundation

nonisolated extension WorkspaceRowContent {
    /// A title template keeps the native breadcrumb/subagent name and the
    /// configured facts in the reducer's order, without inventing another title.
    public enum TitlePart: Hashable, Sendable {
        case name
        case text(String)
    }

    public func displayedTitle(_ name: String) -> String {
        guard let titleParts else { return name }
        return titleParts.map { part in
            switch part { case .name: name; case let .text(text): text }
        }.joined(separator: Self.separator)
    }

    init(_ ws: SidebarWorkspace, layout: WorkspaceRowLayout, now: Date) {
        let working = ws.agentWorking && layout.slots.working
        self.init(icon: layout.slots.icon ? ws.icon : nil,
                  activity: Self.activity(ws.activity, working: working, progress: layout.slots.progress),
                  progress: layout.slots.progress ? Self.bar(ws) : nil, showsWorking: working)
        titleParts = (layout.lines.first ?? []).compactMap { token in
            if token == "name" { return .name }
            return Self.layoutText(token, workspace: ws, now: now).map(TitlePart.text)
        }
        let lines = layout.lines.dropFirst().compactMap { tokens -> String? in
            let text = tokens.compactMap { Self.layoutText($0, workspace: ws, now: now) }.joined(separator: Self.separator)
            return text.isEmpty ? nil : text
        }
        detail = lines.first
        meta = lines.dropFirst().first
    }

    /// Format existing row facts. Token validity and placement were decided by
    /// Rust at settings reload; no FFI, config read or cache mutation happens here.
    private static func layoutText(_ token: String, workspace ws: SidebarWorkspace, now: Date) -> String? {
        guard let element = WorkspaceRowElement(rawValue: token) else { return nil }
        switch element {
        case .tabCount: return String(ws.tabs.count)
        case .pullRequest: return nonEmpty(ws.pullRequest)
        case .log: return ws.reported?.log.flatMap { nonEmpty($0.text) }
        case .agentStatus:
            let entries = ws.reported?.entries.prefix(SidebarWorkspaceStatus.visibleEntryLimit).map(\.displayText) ?? []
            return entries.isEmpty ? nonEmpty(ws.status) : entries.joined(separator: Self.separator)
        default: return text(of: element, in: ws, now: now)
        }
    }
}
