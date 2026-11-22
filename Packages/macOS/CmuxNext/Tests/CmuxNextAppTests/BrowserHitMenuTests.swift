import AppKit
import CmuxNextActions
import CmuxNextBrowser
import Testing
@testable import CmuxNextApp

/// R123 slice B: a right-click on a link, an image or selected text shows
/// one cmux menu in both engines. Chromium reports the hit in its menu
/// params, WebKit through the `contextmenu` hit script; both reports give
/// the same rows (action ids, order, titles), and every row runs its own
/// catalog action through the registry with the hit's address and text.
@MainActor
@Suite struct BrowserHitMenuTests {
    static let tab = ActionTargetRef(kind: .tab, id: "tab-1")
    static let link = "https://example.com/docs?a=1"
    static let image = "https://cdn.example.com/cat.png"

    final class Recorder {
        var runs: [(ActionID, ActionInvocation)] = []
    }

    /// The catalog registry with every action recording its run.
    static func registry(_ recorder: Recorder) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id, invoke: { recorder.runs.append((id, $0)) })
        }
        return registry
    }

    /// "id|title" per row, "---" per separator.
    static func rows(_ items: [NSMenuItem]) -> [String] {
        items.map { item in
            item.isSeparatorItem ? "---" : "\(ActionRegistry.menuRun(of: item)?.id.rawValue ?? "?")|\(item.title)"
        }
    }

    static func ids(_ items: [NSMenuItem]) -> [String] {
        items.compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue }
    }

    static func chromium(link: String = "", source: String = "", media: Int = 0, selection: String = "", editable: Bool = false) -> String {
        #"{"link_url":"\#(link)","source_url":"\#(source)","page_url":"https://example.com/","selection":"\#(selection)","editable":\#(editable),"media_type":\#(media)}"#
    }

    static func webKit(link: String = "", text: String = "", image: String = "", selection: String = "", editable: Bool = false) -> [String: Any] {
        ["link": link, "linkText": text, "image": image, "selection": selection, "editable": editable]
    }

    static func items(_ target: BrowserContextMenuTarget, _ registry: ActionRegistry) -> [NSMenuItem] {
        BrowserHitMenu.items(for: target, tab: tab, registry: registry, searchEngine: "Google")
    }

    /// Runs every row and returns each run (row action, invocation).
    static func runAll(_ items: [NSMenuItem], _ recorder: Recorder) throws -> [(ActionID, ActionInvocation)] {
        var runs: [(ActionID, ActionInvocation)] = []
        for item in items where !item.isSeparatorItem {
            let shown = try #require(ActionRegistry.menuRun(of: item), "\(item.title) is not a generated row")
            recorder.runs.removeAll()
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
            let run = try #require(recorder.runs.first, "\(shown.id) did not run")
            #expect(run.0 == shown.id)
            #expect(run.1.target == tab)
            #expect(run.1.origin == .user)
            runs.append(run)
        }
        return runs
    }

    @Test func aLinkGetsTheSameRowsInBothEngines() throws {
        let recorder = Recorder()
        let registry = Self.registry(recorder)
        var chromium = BrowserContextMenuTarget.chromium(Self.chromium(link: Self.link))
        // Chromium's params carry no link text; CEFTab.linkText(for:) reads it.
        chromium.linkText = "The docs"
        let webKit = try #require(BrowserContextMenuTarget.webKitHit(Self.webKit(link: Self.link, text: "The docs")))
        let fromChromium = Self.items(chromium, registry)
        let fromWebKit = Self.items(webKit, registry)
        #expect(Self.rows(fromChromium) == Self.rows(fromWebKit))
        #expect(Self.ids(fromChromium) == [
            "browser.link.openInNewTab", "browser.link.openInNewWindow", "browser.link.openInNewSpace",
            "browser.link.openInNewWorkspace", "browser.link.openInSplit", "openLinkInDefaultBrowser",
            "browser.link.openInIncognitoWindow",
            "browser.link.saveAs", "browser.link.copy", "browser.link.copyText",
        ])
        for item in fromChromium where !item.isSeparatorItem {
            let id = try #require(ActionRegistry.menuRun(of: item)?.id)
            #expect(item.title == registry.title(for: id), "\(id) shows the catalog title")
        }
        for run in try Self.runAll(fromChromium, recorder) {
            #expect(run.1["url"]?.stringValue == Self.link, "\(run.0) gets the link")
        }
        let copyText = try #require(try Self.runAll(fromWebKit, recorder).first { $0.0 == "browser.link.copyText" })
        #expect(copyText.1["text"]?.stringValue == "The docs")
    }

    @Test func anImageGetsTheSameRowsInBothEngines() throws {
        let recorder = Recorder()
        let registry = Self.registry(recorder)
        let chromium = BrowserContextMenuTarget.chromium(Self.chromium(source: Self.image, media: 1))
        let webKit = try #require(BrowserContextMenuTarget.webKitHit(Self.webKit(image: Self.image)))
        let fromChromium = Self.items(chromium, registry)
        #expect(Self.rows(fromChromium) == Self.rows(Self.items(webKit, registry)))
        #expect(Self.ids(fromChromium) == ["browser.image.openInNewTab", "browser.image.saveAs", "browser.image.copy", "browser.image.copyAddress"])
        for run in try Self.runAll(fromChromium, recorder) {
            #expect(run.1["url"]?.stringValue == Self.image, "\(run.0) gets the image address")
        }
        // A video's source is media, not an image: no image rows.
        #expect(Self.items(BrowserContextMenuTarget.chromium(Self.chromium(source: Self.image, media: 2)), registry).isEmpty)
    }

    @Test func aSelectionGetsTheSameRowsInBothEngines() throws {
        let recorder = Recorder()
        let registry = Self.registry(recorder)
        let selection = "  cmux   terminal\\nfor agents "
        let chromium = BrowserContextMenuTarget.chromium(Self.chromium(selection: selection))
        let webKit = try #require(BrowserContextMenuTarget.webKitHit(Self.webKit(selection: "  cmux   terminal\nfor agents ")))
        let fromChromium = Self.items(chromium, registry)
        #expect(Self.rows(fromChromium) == Self.rows(Self.items(webKit, registry)))
        #expect(Self.ids(fromChromium) == ["browser.selection.copy", "browser.selection.search", "browser.selection.lookUp"])
        #expect(fromChromium.map(\.title).contains(BrowserHitStrings.search(engine: "Google", "cmux terminal for agents")))
        #expect(fromChromium.map(\.title).contains(BrowserHitStrings.lookUp("cmux terminal for agents")))
        for run in try Self.runAll(fromChromium, recorder) {
            #expect(run.1["text"]?.stringValue == "  cmux   terminal\nfor agents ", "\(run.0) gets the selection")
        }
    }

    /// A linked image shows the link rows, then the image rows; a link with
    /// no known text has no Copy Link Text; a selection in an editable field
    /// keeps the engine's own edit rows.
    @Test func sectionsFollowTheHit() {
        let registry = Self.registry(Recorder())
        let both = BrowserContextMenuTarget(linkURL: URL(string: Self.link), linkText: "Cat", imageURL: URL(string: Self.image))
        #expect(BrowserHitMenu.sections(for: both).map(\.context) == [.browserLink, .browserImage])
        #expect(Self.rows(Self.items(both, registry)).contains("---"))
        let bare = BrowserContextMenuTarget(linkURL: URL(string: Self.link))
        #expect(!Self.ids(Self.items(bare, registry)).contains("browser.link.copyText"))
        #expect(BrowserHitMenu.sections(for: BrowserContextMenuTarget(selection: "x", isEditable: true)).isEmpty)
        #expect(BrowserHitMenu.sections(for: BrowserContextMenuTarget(selection: " \n ")).isEmpty)
    }

    @Test func theSearchRowQuotesAShortSnippet() {
        #expect(BrowserHitMenu.snippet("a\n\tb   c") == "a b c")
        let long = String(repeating: "x", count: 80)
        #expect(BrowserHitMenu.snippet(long).count == 50)
        #expect(BrowserHitMenu.snippet(long).hasSuffix("…"))
    }

    /// Keybindings and scripts that name the old id still reach the row.
    @Test func theOldOpenLinkInNewTabIDIsAnAlias() {
        #expect(ActionRegistry.standard().canonicalID(for: "openLinkInNewTab") == "browser.link.openInNewTab")
    }
}
