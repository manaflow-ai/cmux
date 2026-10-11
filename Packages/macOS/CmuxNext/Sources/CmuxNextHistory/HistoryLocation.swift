public import Foundation

/// One place the user was: a tab in a pane of a workspace, on a machine,
/// shown in a window (plans/cmux-next/history.md 4.2).
///
/// Identity is the tab on its machine (`key`): a tab keeps its id when it
/// moves to another pane, workspace or window, so Go Back finds it where it
/// is now. The other fields are the last known context, used to name the
/// location when its machine is offline or its tab is gone.
public nonisolated struct HistoryLocation: Hashable, Sendable, Codable {
    /// The machine-qualified tab: the location's identity.
    public struct Key: Hashable, Sendable, Codable {
        /// The session (machine) id; the home session's own id.
        public var machine: String
        public var tab: String

        public init(machine: String, tab: String) {
            self.machine = machine
            self.tab = tab
        }
    }

    public enum Content: String, Hashable, Sendable, Codable {
        case terminal, browser, other
    }

    public var key: Key
    /// The personal window id that showed it.
    public var window: String
    /// The workspace key on its machine.
    public var workspace: String
    public var pane: String
    public var screen: String?
    public var room: String?
    public var content: Content
    public var title: String
    public var workspaceTitle: String?
    public var machineName: String?
    /// The page URL for a browser tab (context only; page navigations are
    /// the tab's own history, not new locations).
    public var url: String?
    public var cwd: String?
    /// True for an incognito window's location: never written to disk.
    public var isIncognito: Bool
    /// A top page the window showed in place of its workspace (an app route:
    /// `home`, `page:<id>`; TOP-SECTION-ITEMS-ARE-PAGES), else nil. Such an
    /// entry's key is `{top-page, <route>}` with no workspace or pane, and its
    /// content is `other`, so a build without pages decodes the trail and
    /// skips the entry (its "tab" does not exist).
    public var page: String?

    /// The machine id of a page entry's key.
    public static let pageMachine = "top-page"

    /// The trail entry of top page `route` shown in `window`.
    public static func page(_ route: String, window: String, title: String, isIncognito: Bool = false) -> HistoryLocation {
        HistoryLocation(key: Key(machine: pageMachine, tab: route), window: window, workspace: "", pane: "", content: .other,
                        title: title, isIncognito: isIncognito, page: route)
    }

    public init(key: Key, window: String, workspace: String, pane: String, screen: String? = nil,
                room: String? = nil, content: Content, title: String, workspaceTitle: String? = nil,
                machineName: String? = nil, url: String? = nil, cwd: String? = nil, isIncognito: Bool = false, page: String? = nil) {
        self.key = key
        self.window = window
        self.workspace = workspace
        self.pane = pane
        self.screen = screen
        self.room = room
        self.content = content
        self.title = title
        self.workspaceTitle = workspaceTitle
        self.machineName = machineName
        self.url = url
        self.cwd = cwd
        self.isIncognito = isIncognito
        self.page = page
    }
}
