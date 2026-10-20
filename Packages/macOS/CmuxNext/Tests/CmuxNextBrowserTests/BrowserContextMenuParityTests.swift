import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chrome's page menu for each kind of right-click, as Chromium's
/// `RenderViewContextMenu::InitMenu` builds it (ids from
/// `chrome_command_ids.h`), and what cmux keeps of it. Every Chrome row
/// either stays (Chromium runs it) or is replaced by the cmux row named in
/// ``BrowserContextMenuItem/replacedChromiumRows(for:)``; none is lost.
@Suite struct BrowserContextMenuParityTests {
    nonisolated static func rows(_ ids: [Int]) -> [BrowserContextMenuItem] {
        ids.map { $0 == 0 ? BrowserContextMenuItem(id: 0, title: "", kind: .separator) : BrowserContextMenuItem(id: $0, title: "\($0)") }
    }

    nonisolated static let link = URL(string: "https://example.com/a")!
    nonisolated static let image = URL(string: "https://example.com/a.png")!

    /// (name, Chromium's rows, the right-click) for every context.
    nonisolated static let contexts: [(String, [Int], BrowserContextMenuTarget)] = [
        ("page", [33000, 33001, 33002, 0, 35004, 35003, 35011, 51034, 50161, 0, 35002, 50162],
         BrowserContextMenuTarget(pageURL: link)),
        ("link", [50100, 50101, 50102, 0, 50103, 50104, 50107, 0, 50162],
         BrowserContextMenuTarget(linkURL: link, linkText: "A", pageURL: link)),
        ("link without its text", [50100, 50101, 50102, 0, 50103, 50104, 50107, 0, 50162],
         BrowserContextMenuTarget(linkURL: link, pageURL: link)),
        ("image", [50123, 50120, 50122, 50121, 50124, 51034, 0, 50162],
         BrowserContextMenuTarget(sourceURL: image, imageURL: image, pageURL: link)),
        ("linked image", [50100, 50101, 50102, 0, 50103, 50104, 0, 50123, 50120, 50122, 50121, 0, 50162],
         BrowserContextMenuTarget(linkURL: link, sourceURL: image, imageURL: image, pageURL: link)),
        ("canvas", [50120, 50122, 0, 50162], BrowserContextMenuTarget(pageURL: link)),
        ("video", [50140, 50141, 50137, 35011, 0, 50131, 50132, 50136, 0, 50162],
         BrowserContextMenuTarget(sourceURL: URL(string: "https://example.com/v.mp4")!, pageURL: link)),
        ("audio", [50140, 50141, 0, 50131, 50132, 50136, 0, 50162],
         BrowserContextMenuTarget(sourceURL: URL(string: "https://example.com/a.mp3")!, pageURL: link)),
        ("selection", [50150, 50158, 50191, 35003, 50179, 0, 50165, 0, 50162],
         BrowserContextMenuTarget(pageURL: link, selection: "hello world")),
        ("white space selection", [50150, 0, 50162], BrowserContextMenuTarget(pageURL: link, selection: "  \n")),
        ("editable", [50167, 41110, 0, 50220, 0, 50154, 50155, 0, 50151, 50150, 50152, 50157, 50153, 50156, 0, 50165, 57329, 57328, 0, 50162],
         BrowserContextMenuTarget(pageURL: link, selection: "teh", isEditable: true)),
        ("frame", [33000, 33001, 33002, 0, 50180, 50181, 0, 50162], BrowserContextMenuTarget(pageURL: link)),
    ]

    @Test(arguments: contexts.indices) func noChromeRowIsLost(_ index: Int) {
        let (name, ids, target) = Self.contexts[index]
        let kept = Set(BrowserContextMenuItem.withoutHitItems(Self.rows(ids), for: target).map(\.id))
        let replaced = BrowserContextMenuItem.replacedChromiumRows(for: target)
        for id in ids where id != 0 {
            #expect(kept.contains(id) != (replaced[id] != nil), "\(name): Chrome row \(id) kept \(kept.contains(id)), replaced by \(replaced[id] ?? "nothing")")
        }
    }

    /// A canvas has Save Image As and Copy Image but no image address: no
    /// cmux row replaces them, so Chromium's stay.
    @Test func canvasKeepsChromiumsImageRows() {
        let kept = BrowserContextMenuItem.withoutHitItems(Self.rows([50120, 50122, 0, 50162]), for: BrowserContextMenuTarget())
        #expect(kept.map(\.id) == [50120, 50122, 0, 50162])
    }

    /// Copy Link Text stays Chromium's when cmux could not read the text.
    @Test func linkWithoutTextKeepsChromiumsCopyLinkText() {
        let kept = BrowserContextMenuItem.withoutHitItems(Self.rows([50100, 50104, 50107]), for: BrowserContextMenuTarget(linkURL: Self.link))
        #expect(kept.map(\.id) == [50107])
    }

    /// Chromium's hidden rows (an extension item with `visible: false`) and
    /// submenus with no visible child are not shown, as in Chrome.
    @Test func hiddenRowsAreDropped() {
        let json = """
        [{"id": 33000, "label": "&Back", "type": "command", "visible": true},
         {"id": 0, "type": "separator"},
         {"id": 49000, "label": "Hidden", "type": "command", "visible": false},
         {"id": 49001, "label": "Ext", "type": "submenu", "items": [{"id": 49002, "label": "Gone", "visible": false}]},
         {"id": 0, "type": "separator"},
         {"id": 49003, "label": "Group", "type": "submenu", "items": [
            {"id": 49004, "label": "A", "type": "check", "checked": true},
            {"id": 49005, "label": "B", "visible": false},
            {"id": 0, "type": "separator"},
            {"id": 49006, "label": "R", "type": "radio", "checked": false}]},
         {"id": 50162, "label": "I&nspect"}]
        """
        let items = BrowserContextMenuItem.decodeList(json)
        #expect(items.map(\.id) == [33000, 0, 49003, 50162])
        #expect(items[0].title == "Back")
        #expect(items[2].children.map(\.id) == [49004, 0, 49006])
        #expect(items[2].children.map(\.kind) == [.check, .separator, .radio])
        #expect(items[2].children[0].isChecked)
    }

    /// Chrome on macOS draws icons on Translate and Cast…; cmux does too.
    @Test func chromeRowsWithIconsGetThem() {
        let items = BrowserContextMenuItem.withChromeIcons(Self.rows([50161, 35011, 50162]) + [
            BrowserContextMenuItem(id: 1, title: "Sub", kind: .submenu, children: Self.rows([50179])),
        ])
        #expect(items[0].icon == .symbol("translate"))
        #expect(items[1].icon == .symbol("airplayvideo"))
        #expect(items[2].icon == nil)
        #expect(items[3].children[0].icon == .symbol("translate"))
    }

    /// The work a right-click adds stays far below a frame: decoding a
    /// 60-row menu with three extensions, matching their icons and making
    /// the menu items (images cached after the first menu).
    @Test @MainActor func aMenuWithExtensionsOpensFast() throws {
        let rows: [String] = (0..<50).map { #"{"id": \#(33000 + $0), "label": "Row \#($0)"}"# } + [
            #"{"id": 49000, "label": "1Password", "type": "submenu", "items": [{"id": 49001, "label": "Fill"}, {"id": 49002, "label": "Save"}]}"#,
            #"{"id": 49003, "label": "Bitwarden", "type": "submenu", "items": [{"id": 49004, "label": "Fill"}]}"#,
            #"{"id": 49005, "label": "Save to Pocket"}"#,
        ]
        let json = "[" + rows.joined(separator: ",") + "]"
        let icons = BrowserExtensionMenuIcons(sources: [
            BrowserExtensionMenuIconsTests.onePassword, BrowserExtensionMenuIconsTests.bitwarden, BrowserExtensionMenuIconsTests.pocket,
        ])
        let builder = BrowserContextMenuBuilder()
        func open() -> [NSMenuItem] {
            let items = BrowserContextMenuItem.withChromeIcons(icons.annotate(BrowserContextMenuItem.decodeList(json)))
            return builder.items(for: BrowserContextMenuRequest(items: items, target: BrowserContextMenuTarget(), location: .zero) { _ in })
        }
        #expect(open().count == 53)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<20 { times.append(clock.measure { _ = open() }) }
        let median = times.sorted()[times.count / 2]
        #expect(median < .milliseconds(4), "median \(median)")
    }
}
