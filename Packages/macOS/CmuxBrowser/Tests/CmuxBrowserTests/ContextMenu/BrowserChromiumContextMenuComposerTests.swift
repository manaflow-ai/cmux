import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserChromiumContextMenuComposerTests {
    private let link = URL(string: "https://example.com/a")!

    private func item(_ id: Int, _ title: String = "") -> BrowserContextMenuItem {
        BrowserContextMenuItem(id: id, title: title)
    }

    private var separator: BrowserContextMenuItem { BrowserContextMenuItem(id: -1, title: "", kind: .separator) }

    @Test func decodesTheShimModelAndStripsMnemonics() {
        let json = """
        [{"id":50100,"label":"Open Link in New &Tab","type":"command","enabled":true,"checked":false},
         {"id":-1,"label":"","type":"separator"},
         {"id":7,"label":"Spell &&Grammar","type":"submenu","items":[{"id":8,"label":"Check","type":"check","checked":true}]},
         {"id":9,"label":"Off","enabled":false}]
        """
        let items = BrowserContextMenuItem.decodeChromiumList(json)
        #expect(items.count == 4)
        #expect(items[0] == BrowserContextMenuItem(id: 50100, title: "Open Link in New Tab"))
        #expect(items[1].kind == .separator)
        #expect(items[2].title == "Spell &Grammar")
        #expect(items[2].children == [BrowserContextMenuItem(id: 8, title: "Check", kind: .check, isChecked: true)])
        #expect(items[3].isEnabled == false && items[3].kind == .command)
        #expect(BrowserContextMenuItem.decodeChromiumList("not json").isEmpty)
    }

    @Test func decodesChromiumParams() {
        let target = BrowserContextMenuTarget(chromiumParamsJSON: """
        {"link_url":"https://example.com/a","source_url":"https://example.com/i.png","page_url":"https://example.com/",
         "selection":"hi","editable":false,"media_type":1}
        """)
        #expect(target.linkURL == link)
        #expect(target.imageURL == URL(string: "https://example.com/i.png"))
        #expect(target.selection == "hi")
        let video = BrowserContextMenuTarget(chromiumParamsJSON: #"{"source_url":"https://e.com/v.mp4","media_type":2,"link_url":""}"#)
        #expect(video.imageURL == nil && video.sourceURL != nil && video.linkURL == nil)
        #expect(BrowserContextMenuTarget(chromiumParamsJSON: "{") == BrowserContextMenuTarget())
    }

    @Test func insertsDefaultBrowserAfterOpenInNewTabAndHidesWindowRows() {
        let entries = BrowserChromiumContextMenuComposer().compose(
            items: [item(50100, "New Tab"), item(50101, "New Window"), item(50102, "Incognito"), item(50104, "Copy Link"),
                    separator, item(50162, "Inspect")],
            target: BrowserContextMenuTarget(linkURL: link),
            defaultBrowserLink: link,
            hostGroups: [[.screenshotPage, .screenshotSection], [], [.moveTabToNewWorkspace], [.toggleFocusMode(isActive: false)]]
        )
        #expect(entries == [
            .engine(item(50100, "New Tab")), .host(.openLinkInDefaultBrowser(link)), .engine(item(50104, "Copy Link")),
            .separator, .engine(item(50162, "Inspect")),
            .separator, .host(.screenshotPage), .host(.screenshotSection),
            .separator, .host(.moveTabToNewWorkspace),
            .separator, .host(.toggleFocusMode(isActive: false)),
        ])
    }

    @Test func linkWithoutOpenInNewTabLeadsWithDefaultBrowser() {
        let entries = BrowserChromiumContextMenuComposer().compose(
            items: [item(1, "Back")], target: BrowserContextMenuTarget(linkURL: link), defaultBrowserLink: link, hostGroups: []
        )
        #expect(entries == [.host(.openLinkInDefaultBrowser(link)), .separator, .engine(item(1, "Back"))])
    }

    @Test func noDefaultBrowserRowWithoutALinkOrPermission() {
        let composer = BrowserChromiumContextMenuComposer()
        let noLink = composer.compose(items: [item(1)], target: BrowserContextMenuTarget(), defaultBrowserLink: link, hostGroups: [])
        #expect(noLink == [.engine(item(1))])
        let notAllowed = composer.compose(
            items: [item(50100)], target: BrowserContextMenuTarget(linkURL: link), defaultBrowserLink: nil, hostGroups: []
        )
        #expect(notAllowed == [.engine(item(50100))])
    }

    @Test func separatorsNeverLeadTrailOrDouble() {
        let entries = BrowserChromiumContextMenuComposer().compose(
            items: [separator, item(50101), separator, separator, item(2), separator, item(50102), separator],
            target: BrowserContextMenuTarget(), defaultBrowserLink: nil, hostGroups: [[.screenshotPage]]
        )
        #expect(entries == [.engine(item(2)), .separator, .host(.screenshotPage)])
        #expect(BrowserChromiumContextMenuComposer().compose(
            items: [separator], target: BrowserContextMenuTarget(), defaultBrowserLink: nil, hostGroups: []
        ).isEmpty)
    }

    @Test func submenusLoseHiddenRowsAndEmptySubmenusDisappear() {
        let submenu = BrowserContextMenuItem(id: 10, title: "More", kind: .submenu, children: [item(50101), item(11)])
        let empty = BrowserContextMenuItem(id: 12, title: "Gone", kind: .submenu, children: [item(50102)])
        let entries = BrowserChromiumContextMenuComposer().compose(
            items: [submenu, empty], target: BrowserContextMenuTarget(), defaultBrowserLink: nil, hostGroups: []
        )
        #expect(entries == [.engine(BrowserContextMenuItem(id: 10, title: "More", kind: .submenu, children: [item(11)]))])
    }
}
