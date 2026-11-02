import Foundation

/// Send Message… on a workspace or a tab (the Mac's `home.messageAbout`): a message to the
/// Chief that starts with a link to it, the way the Mac's Home message box gets a link chip.
/// The link is the Mac's own grammar (`cmux://workspace/<ws_>`, `cmux://tab/<tab_>`), so the
/// Chief opens what it names.
public struct ChiefMessageAbout: Identifiable, Hashable, Sendable {
    /// What the link names, as the menu showed it.
    public var title: String
    public var link: String
    /// The Mac the workspace or tab is on (the Chief there gets the message).
    public var macID: String

    public var id: String { link }

    public init(title: String, link: String, macID: String) {
        self.title = title
        self.link = link
        self.macID = macID
    }

    /// The workspace's link, nil when the Mac's tree did not carry its public id.
    public init?(workspace: Workspace) {
        guard let id = workspace.resourceID, id.hasPrefix("ws_") else { return nil }
        self.init(title: workspace.title, link: "cmux://workspace/\(id)", macID: workspace.macID)
    }

    /// The tab's link, nil when the Mac's tree did not carry its public id.
    public init?(tab: WorkspaceTab, in workspace: Workspace) {
        guard let id = tab.linkIDs?.tab, id.hasPrefix("tab_") else { return nil }
        let title = tab.isAgent ? (tab.task ?? tab.title) : tab.title
        self.init(title: title, link: "cmux://tab/\(id)", macID: workspace.macID)
    }

    /// The message's start: a Markdown link chip, as the Mac writes it (`HomeMessageRouting.mention`).
    public var mention: String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(label.isEmpty ? link : label)](\(link)) "
    }
}

/// Opens the message to the Chief for a workspace or a tab. The shell sets `compose`
/// (it owns Home and the Chief); the menus offer Send Message… only while it is set.
@MainActor
public final class ChiefMessenger {
    public static let shared = ChiefMessenger()

    public var compose: ((ChiefMessageAbout) -> Void)?

    public init() {}

    public var isAvailable: Bool { compose != nil }

    public func messageAbout(_ subject: ChiefMessageAbout) {
        compose?(subject)
    }
}
