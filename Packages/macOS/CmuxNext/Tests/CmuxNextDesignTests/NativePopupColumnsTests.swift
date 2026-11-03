import AppKit
@testable import CmuxNextDesign
import Testing

/// The columns layout draws the web model picker's columns (harness rail, models, then the shown
/// model's effort and Fast) side by side under the search row and its account accessory, moves the
/// keyboard's highlight within and between columns, and never shrinks while open.
@MainActor @Suite(.serialized) struct NativePopupColumnsTests {
    @Test func columnsRoundTripAndRejectMalformedShapes() throws {
        let model = Self.model()
        #expect(model.isValid)
        let data = try JSONEncoder().encode(model)
        let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((params["columns"] as? [[String: Any]])?.count == 3)
        #expect(NativePopupModel.decode(params) == model)

        var bad = model
        bad.rail = [NativePopupRow(id: "railed", kind: .action, label: "Rail")]
        #expect(!bad.isValid, "a popup is columns or a rail, never both")
        bad = model
        bad.columns?[1].width = 400
        #expect(!bad.isValid, "fixed columns never add up past the popup")
        bad = model
        bad.columns?[2].rows.append(NativePopupRow(id: "opus", kind: .action, label: "Twin"))
        #expect(!bad.isValid, "ids stay unique across columns")
        bad = model
        bad.columns = nil
        #expect(!bad.isValid, "a band height needs columns")
        bad = model
        bad.search = nil
        #expect(!bad.isValid, "the accessory sits in the search row")
        bad = model
        bad.columns?[0].id = "models"
        #expect(!bad.isValid, "column ids are unique")
        #expect(model.allRows.map(\.id) == ["account", "auth", "starred", "claude", "codex", "opus", "sonnet", "haiku",
                                             "effort-head", "high", "medium", "fast", "update"])
    }

    @Test func columnsSitSideBySideUnderTheSearchRow() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 350, height: 10))
        content.update(Self.model())
        #expect(content.columnViews.map(\.frame.minX) == [0, 48, 197])
        #expect(content.columnViews.map(\.frame.width) == [48, 149, 153], "the last column takes the rest")
        let accessory = try #require(content.searchAccessoryTab)
        #expect(accessory.frame.maxX <= 48, "the avatar sits over the rail")
        let search = try #require(content.search)
        #expect(search.frame.minX >= 48 && search.frame.maxY <= NativePopupContent.columnsSearchRow)
        let auth = try #require(content.rowView(id: "auth"))
        #expect(auth.frame.width > 300, "a spanning row crosses every column")
        let band = content.columnViews[1].frame
        #expect(band.minY >= auth.frame.maxY)
        let opus = try #require(content.rowView(id: "opus"))
        #expect(opus.isDescendant(of: content.columnViews[1].document))
        #expect(try #require(content.rowView(id: "claude")).isDescendant(of: content.columnViews[0].document))
        #expect(try #require(content.rowView(id: "fast")).isDescendant(of: content.columnViews[2].document))
        let update = try #require(content.rowView(id: "update"))
        #expect(update.frame.minY >= band.maxY, "the footer sits under the columns")
        #expect(content.contentHeight >= update.frame.maxY)
        let tabs = content.columnViews[0].document.subviews.compactMap { $0 as? NativePopupRailTab }
        #expect(tabs.count == 3 && tabs.allSatisfy { !$0.showsAccentBar && $0.nameLabel == nil })
    }

    @Test func aLongColumnScrollsUnderTheCapAndTheBandNeverShrinks() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 350, height: 10))
        var model = Self.model()
        model.columns?[1].rows = (0 ..< 20).map { NativePopupRow(id: "m\($0)", kind: .action, label: "Model \($0)") }
        content.update(model)
        let tall = content.columnViews[1]
        #expect(tall.frame.height == 220)
        #expect(tall.document.frame.height > tall.frame.height, "the models column scrolls on its own")
        model.revision += 1
        model.columns?[1].rows = [NativePopupRow(id: "only", kind: .action, label: "Only")]
        content.update(model)
        #expect(content.columnViews[1].frame.height == 220, "a tab with fewer rows keeps the menu's size")
    }

    @Test func arrowsMoveWithinAndBetweenColumns() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 350, height: 10))
        var highlights: [String?] = []
        var picks: [String?] = []
        var changes: [(String?, String?)] = []
        content.emit = { type, id, value in
            switch type {
            case .highlight: highlights.append(id)
            case .pick: picks.append(id)
            case .change: changes.append((id, value))
            default: break
            }
        }
        content.update(Self.model())
        #expect(content.selected == "opus", "the highlight starts in the models, never on a harness tab")
        #expect(content.handleKey(126) && content.selected == "opus", "Up stops at the column's top")
        #expect(content.handleKey(125) && content.handleKey(125) && content.handleKey(125))
        #expect(content.selected == "haiku", "Down stays in the column and stops at its end")
        #expect(content.handleKey(124) && content.selected == "medium", "Right lands on the checked level")
        #expect(content.handleKey(125) && content.selected == "fast")
        #expect(content.handleKey(124) && content.selected == "fast", "past the last column it stays")
        #expect(content.handleKey(36) && changes.first?.0 == "fast" && changes.first?.1 == "true")
        #expect(content.handleKey(123) && content.handleKey(123) && content.selected == "claude",
                "Left reaches the rail's checked tab")
        #expect(content.handleKey(125) && content.selected == "codex")
        #expect(content.handleKey(36) && picks == ["codex"])
        #expect(highlights == ["sonnet", "haiku", "medium", "fast", "opus", "claude", "codex"])
    }

    @Test func theAccessoryOpensItsChildrenBesideThePopup() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 350, height: 10))
        var opened: [String] = []
        content.openSubmenu = { row, _ in opened.append(row.id) }
        content.update(Self.model())
        let accessory = try #require(content.searchAccessoryTab)
        #expect(accessory.accessibilityPerformPress())
        #expect(opened == ["account"])
        #expect(!content.enabledRows.contains { $0.0.id == "account" }, "the arrows never reach the avatar")
        #expect(content.rowView(id: "account") === accessory)
    }

    static func model() -> NativePopupModel {
        let rail = NativePopupColumn(id: "rail", label: "Harness", width: 48, rail: true, rows: [
            NativePopupRow(id: "starred", kind: .action, label: "Starred", icon: "browser.omnibox.star"),
            NativePopupRow(id: "claude", kind: .action, label: "Claude", checked: true, mark: "claude"),
            NativePopupRow(id: "codex", kind: .action, label: "Codex", monogram: "C"),
        ])
        let models = NativePopupColumn(id: "models", label: "Model", width: 149, rows: [
            NativePopupRow(id: "opus", kind: .action, label: "Opus 5.5", checked: true, keepOpen: true),
            NativePopupRow(id: "sonnet", kind: .action, label: "Sonnet 5.5", keepOpen: true),
            NativePopupRow(id: "haiku", kind: .action, label: "Haiku 5.5", keepOpen: true),
        ])
        let tune = NativePopupColumn(id: "tune", label: "Effort", rows: [
            NativePopupRow(id: "effort-head", kind: .section, label: "Effort"),
            NativePopupRow(id: "high", kind: .action, label: "High", keepOpen: true),
            NativePopupRow(id: "medium", kind: .action, label: "Medium", checked: true, keepOpen: true),
            NativePopupRow(id: "fast", kind: .toggle, label: "Fast", checked: false),
        ])
        let account = NativePopupRow(id: "account", kind: .submenu, label: "Claude · Account: Leo", monogram: "L",
                                     children: [NativePopupRow(id: "account-add", kind: .action, label: "Add account…")])
        return NativePopupModel(schemaVersion: 1, id: "picker", revision: 1,
                                anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                side: .bottom, align: .start, width: 350,
                                rows: [NativePopupRow(id: "auth", kind: .text, label: "Signed out")],
                                search: NativePopupField(id: "query", value: "", placeholder: "Search"),
                                footer: [NativePopupRow(id: "update", kind: .action, label: "Update")],
                                columns: [rail, models, tune], columnsHeight: 220, searchAccessory: account)
    }
}
