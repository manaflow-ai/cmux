import Foundation

/// The part of a New Tab context (``AgentPaneNewTab``) that the New Tab pages of this Mac have in common at one
/// time: the kinds' chords, the project folders, the design, the last picks, the warm chat list and each list of
/// the bar but its open tabs. It is the large part (every workspace, every palette action, the recent pages with
/// their icons). The app makes its JSON text one time for each value (``AgentPaneNewTabText``), and a page's
/// document gets that text one time (``AgentPaneModel/newTabSharedGeneration``). The rest is the page's own
/// part (``AgentPaneNewTab/ownTree``): the key's input token, the folder, the bar's open tabs and each other
/// small field. The page joins the two (webviews newtab/sharedPart.ts).
nonisolated struct AgentPaneNewTabShared: Encodable, Equatable {
    /// The bar's lists that are not a page's own: all but `tabs`, by the keys of ``AgentPaneOmnibar``.
    nonisolated struct Bar: Encodable, Equatable {
        var workspaces: [AgentPaneOmnibar.Workspace]
        var folders: [String]
        var projects: [String]
        var actions: [AgentPaneOmnibar.Action]
        var commands: [String]
        var history: [AgentPaneOmnibar.Page]
        var bookmarks: [AgentPaneOmnibar.Page]
        var uses: [String: Double]
        var profiles: [AgentPaneOmnibar.Profile]?
    }

    var hotkeys: [String: String]
    var projects: [String]
    var layout: AgentPaneNewTabLayout?
    var lastPicks: AgentPaneLastPicks?
    var warm: String?
    var omnibar: Bar

    init(_ page: AgentPaneNewTab) {
        hotkeys = page.hotkeys
        projects = page.projects
        layout = page.layout
        lastPicks = page.lastPicks
        warm = page.warm
        let bar = page.omnibar
        omnibar = Bar(workspaces: bar.workspaces, folders: bar.folders, projects: bar.projects, actions: bar.actions,
                      commands: bar.commands, history: bar.history, bookmarks: bar.bookmarks, uses: bar.uses,
                      profiles: bar.profiles)
    }
}

extension AgentPaneNewTab {
    /// The page's own part as a JSON tree: the context with no key of the shared part (``AgentPaneNewTabShared``).
    /// The context's own encoding makes it, so a field added to the context is in this part until the shared
    /// part takes it.
    nonisolated var ownTree: [String: Any]? {
        var page = self
        (page.hotkeys, page.projects, page.projectRows, page.layout, page.lastPicks, page.warm) = ([:], [], nil, nil, nil, nil)
        page.omnibar = AgentPaneOmnibar(tabs: omnibar.tabs)
        guard let data = try? JSONEncoder().encode(page),
              var tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        tree.removeValue(forKey: "hotkeys")
        tree.removeValue(forKey: "projects")
        tree["omnibar"] = ["tabs": (tree["omnibar"] as? [String: Any])?["tabs"] ?? [Any]()]
        return tree
    }
}

/// Makes the JSON text of the shared part of a New Tab context (``AgentPaneNewTabShared``) and keeps it: the
/// part is large, so each make is main thread time in a New Tab key's frames. An equal part gets the kept
/// text, so the pages of a held New Tab key cost one make. Each text has a generation, the count of makes at
/// its own: a page's model keeps the generation that its document has. `encodes` counts the makes, for the
/// tests that hold how many pages cost one.
/// The composition root owns one (``AgentPaneShared/newTabText``) and each page's view gives it to its model
/// (``AgentPaneModel/newTabText``), so each page gets the same kept text; a model with its own shares none.
@MainActor public final class AgentPaneNewTabText {
    /// The parts kept. More than one, because the app's pages have a few at one time: a key's context before
    /// the palette's actions are listed and after, and a parked spare's context with an empty bar.
    static let capacity = 4

    public private(set) var encodes = 0
    private var kept: [(part: AgentPaneNewTabShared, text: String, generation: Int)] = []

    public init() {}

    /// The shared part of `page` as JSON text, with its generation; nil when it has no JSON.
    func text(of page: AgentPaneNewTab) -> (text: String, generation: Int)? {
        let part = AgentPaneNewTabShared(page)
        if let index = kept.firstIndex(where: { $0.part == part }) {
            // The newest use first: the part that goes out at the limit is the one not used for the longest time.
            let entry = kept.remove(at: index)
            kept.insert(entry, at: 0)
            return (entry.text, entry.generation)
        }
        guard let data = try? JSONEncoder().encode(part), let text = String(data: data, encoding: .utf8) else { return nil }
        encodes += 1
        kept.insert((part, text, encodes), at: 0)
        if kept.count > Self.capacity { kept.removeLast() }
        return (text, encodes)
    }
}

extension AgentPaneModel {
    /// The JSON trees of a New Tab context for this page: its own part, with `sharedGeneration` (the generation
    /// of the shared text that it goes with), and the shared text when this page's document does not have that
    /// generation or `always` is set. The document has it from here on.
    private func newTabParts(_ page: AgentPaneNewTab, always: Bool) -> (own: [String: Any], shared: String?)? {
        guard var own = page.ownTree, let shared = newTabText.text(of: page) else { return nil }
        own["sharedGeneration"] = shared.generation
        let sends = always || newTabSharedGeneration != shared.generation
        newTabSharedGeneration = shared.generation
        return (own, sends ? shared.text : nil)
    }

    /// `newTab` of a reply to the page (`newTab.context`'s answer, the handshake): the page's own part, and the
    /// shared text as its `shared` string when the page's document does not have it. `always`: the page asked
    /// for its context, so it gets the shared text whatever the mark says (a document that lost it asks again).
    func newTabReply(_ page: AgentPaneNewTab, always: Bool = false) -> [String: Any]? {
        guard var parts = newTabParts(page, always: always) else { return nil }
        if let shared = parts.shared { parts.own["shared"] = shared }
        return parts.own
    }

    /// The whole context as a script's value (the adopt event's detail, the context a document gets at its
    /// commit): the page's own part joined with the shared part. The shared text goes in as it is, and only
    /// when the page's document does not have it (`always`: a new document has none); the document keeps it in
    /// `__cmuxNewTabShared` for the next join. A document that has another generation gets the own part only,
    /// and asks for its context again (webviews newtab/sharedPart.ts).
    func newTabScriptValue(_ page: AgentPaneNewTab, always: Bool = false) -> String? {
        guard let parts = newTabParts(page, always: always), let data = try? JSONSerialization.data(withJSONObject: parts.own),
              let own = String(data: data, encoding: .utf8) else { return nil }
        let shared = parts.shared.map { "," + $0 } ?? ""
        return "(" + AgentPaneModel.newTabJoin + ")(" + own + shared + ")"
    }

    /// Joins a page's own part `o` with the shared part: `s` when the script has it (kept from here), else the
    /// one the document keeps when it is of the own part's generation.
    private static let newTabJoin = "function(o,s){var w=window,k=w.__cmuxNewTabShared;"
        + "if(s){k=w.__cmuxNewTabShared={generation:o.sharedGeneration,value:s}}"
        + "return k&&k.generation===o.sharedGeneration"
        + "?Object.assign({},k.value,o,{omnibar:Object.assign({},k.value.omnibar,o.omnibar)}):o}"
}
