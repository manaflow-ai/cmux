import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium's page menu loses the link, image and selection rows that the
/// cmux rows replace (R123 slice B); extension rows, Inspect and the
/// editable field's own Copy stay.
@MainActor
struct ChromiumHitRowsTests {
    static func item(_ id: Int, _ title: String = "") -> BrowserContextMenuItem {
        BrowserContextMenuItem(id: id, title: title.isEmpty ? "\(id)" : title)
    }

    static let separator = BrowserContextMenuItem(id: -1, title: "", kind: .separator)

    static let linkMenu = [
        item(50100), item(50102), separator, item(50103), item(50104), item(50107), separator,
        item(50150), item(50191), separator, item(47000, "Extension"), separator, item(50162, "Inspect"),
    ]

    @Test func cmuxRowsReplaceChromiumsHitRows() {
        let target = BrowserContextMenuTarget(linkURL: URL(string: "https://example.com"), selection: "x")
        let kept = BrowserContextMenuItem.withoutHitItems(Self.linkMenu, for: target)
        #expect(kept.map(\.id) == [47000, -1, 50162])
    }

    @Test func anEditableFieldKeepsChromiumsCopy() {
        let kept = BrowserContextMenuItem.withoutHitItems([Self.item(50151), Self.item(50150), Self.item(50152)],
                                                          for: BrowserContextMenuTarget(selection: "x", isEditable: true))
        #expect(kept.map(\.id) == [50151, 50150, 50152])
    }

    @Test func imageRowsGoToo() {
        let menu = [Self.item(50123), Self.item(50120), Self.item(50122), Self.item(50121), Self.separator, Self.item(50124, "Search image")]
        #expect(BrowserContextMenuItem.withoutHitItems(menu, for: BrowserContextMenuTarget()).map(\.id) == [50124])
    }

    @Test func chromiumParamsNameTheImage() {
        let json = #"{"link_url":"","source_url":"https://e.com/a.png","page_url":"https://e.com/","selection":"","editable":false,"media_type":1}"#
        let target = BrowserContextMenuTarget.chromium(json)
        #expect(target.imageURL?.absoluteString == "https://e.com/a.png")
        #expect(target.linkURL == nil)
        let video = BrowserContextMenuTarget.chromium(json.replacingOccurrences(of: #""media_type":1"#, with: #""media_type":2"#))
        #expect(video.imageURL == nil)
        #expect(video.sourceURL?.absoluteString == "https://e.com/a.png")
    }

    @Test func webKitReportsDecode() {
        let target = BrowserContextMenuTarget.webKitHit(["link": "https://e.com/x", "linkText": "X", "image": "", "selection": "s", "editable": true])
        #expect(target == BrowserContextMenuTarget(linkURL: URL(string: "https://e.com/x"), linkText: "X", selection: "s", isEditable: true))
        #expect(BrowserContextMenuTarget.webKitHit("junk") == nil)
    }
}
