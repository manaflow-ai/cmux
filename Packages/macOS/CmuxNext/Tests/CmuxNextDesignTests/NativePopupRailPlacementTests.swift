import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The rail draws the web picker's four harness placements (symbols, left, top, compact), keeps
/// Up and Down in the list, hands Left and Right to the page, and never replaces a dragged slider.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativePopupRailPlacementTests {
    @Test func placementMarksAndNavigateRoundTrip() throws {
        var model = Self.model(.compact)
        model.railWidth = 76
        let data = try JSONEncoder().encode(model)
        let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(params["railPlacement"] as? String == "compact")
        #expect(NativePopupModel.decode(params) == model)
        let event = try JSONDecoder().decode(NativePopupEvent.self, from: Data(#"{"type":"navigate","popupId":"p","revision":1,"value":"next"}"#.utf8))
        #expect(event.type == .navigate && event.value == "next")
        model.rail?[0].monogram = ""
        #expect(!model.isValid)
        model.rail?[0].monogram = "123456789"
        #expect(!model.isValid)
    }

    @Test func symbolsRowWrapsMarksAboveTheListUnderAFullWidthSearch() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 120, height: 10))
        var model = Self.model(.symbols, tabs: 6)
        model.search = NativePopupField(id: "query", value: "", placeholder: "Search")
        content.update(model)
        let tabs = Self.tabs(content)
        #expect(tabs.count == 7)
        #expect(tabs.allSatisfy { $0.nameLabel == nil }, "the symbols row is marks only")
        #expect(tabs.allSatisfy { $0.frame.size == NSSize(width: PopupStyle.standard.rowHeight, height: PopupStyle.standard.rowHeight) })
        #expect(Set(tabs.map(\.frame.minY)).count > 1, "the row wraps instead of cutting a symbol")
        #expect(tabs.allSatisfy { $0.frame.maxX <= 120 })
        let strip = try #require(content.railStrip)
        #expect(tabs.allSatisfy { $0.isDescendant(of: strip) })
        let search = try #require(content.search)
        #expect(search.frame.minX < 10 && search.frame.maxX > 110, "the search spans the menu")
        let row = try #require(content.rowView(id: "model"))
        #expect(row.frame.minY >= strip.frame.maxY && row.frame.minX < 10)
        #expect(tabs.first { $0.row.id == "tab-1" }?.isSelected == true)
        #expect(tabs.first { $0.row.id == "tab-0" }?.themedToolTip == "Tab 0")
    }

    @Test func symbolsRowScrollsPastThreeRows() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 80, height: 10))
        content.update(Self.model(.symbols, tabs: 12))
        let strip = try #require(content.railStrip)
        let document = try #require(strip.documentView)
        #expect(Self.tabs(content).allSatisfy { $0.superview === document }, "the first opening fills the strip")
        #expect(strip.frame.height == Metrics.space2 + 3 * PopupStyle.standard.rowHeight + 3 * Metrics.space1)
        #expect(document.frame.height > strip.frame.height)
    }

    @Test func topStripNamesItsTabs() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        content.update(Self.model(.top))
        let tabs = Self.tabs(content)
        #expect(tabs.allSatisfy { $0.nameLabel?.stringValue == $0.row.label })
        #expect(tabs.allSatisfy { $0.frame.height == PopupStyle.standard.rowHeight && $0.frame.width > PopupStyle.standard.rowHeight })
        let strip = try #require(content.railStrip)
        #expect(try #require(content.rowView(id: "model")).frame.minY >= strip.frame.maxY)
    }

    @Test(arguments: [NativePopupRailPlacement.left, .compact])
    func columnPlacementsSitBesideTheList(placement: NativePopupRailPlacement) throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        var model = Self.model(placement)
        model.railWidth = placement == .compact ? 68 : 115
        content.update(model)
        #expect(content.railStrip == nil)
        let tabs = Self.tabs(content)
        #expect(tabs.allSatisfy { $0.superview === content && $0.frame.maxX <= CGFloat(model.railWidth ?? 0) })
        let row = try #require(content.rowView(id: "model"))
        #expect(row.frame.minX >= CGFloat(model.railWidth ?? 0))
        let tab = try #require(tabs.first { $0.row.id == "tab-0" })
        tab.layoutSubtreeIfNeeded()
        let mark = try #require(tab.markView)
        let name = try #require(tab.nameLabel)
        if placement == .compact {
            #expect(name.frame.minY >= mark.frame.maxY, "the compact rail puts each name under its mark")
        } else {
            #expect(name.frame.minX >= mark.frame.maxX, "the left rail puts each name beside its mark")
        }
    }

    @Test func upAndDownStayInTheListWhileLeftAndRightAskThePage() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        var model = Self.model(.symbols)
        model.rows.append(NativePopupRow(id: "effort", kind: .submenu, label: "Effort",
                                         children: [NativePopupRow(id: "high", kind: .action, label: "High")]))
        var events: [(NativePopupEventType, String?, String?)] = []
        var opened: [String] = []
        content.emit = { events.append(($0, $1, $2)) }
        content.openSubmenu = { row, _ in opened.append(row.id) }
        content.update(model)
        #expect(content.selected == "model", "the list's first row, never a rail tab")
        #expect(content.handleKey(125) && content.selected == "effort")
        #expect(content.handleKey(125) && content.selected == "model", "Down wraps within the list")
        #expect(content.handleKey(124))
        #expect(content.handleKey(123))
        #expect(events.filter { $0.0 == .navigate }.map { $0.2 } == ["next", "previous"])
        #expect(events.allSatisfy { $0.0 != .navigate || $0.1 == nil })
        _ = content.handleKey(125)
        #expect(content.handleKey(124) && opened == ["effort"], "Right opens a side dropdown")
    }

    @Test func emptySearchFieldStepsTheRail() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.closeAfterTest() }
        var model = Self.model(.symbols)
        model.search = NativePopupField(id: "query", value: "", placeholder: "Search")
        var values: [String?] = []
        content.emit = { type, _, value in if type == .navigate { values.append(value) } }
        content.update(model)
        let search = try #require(content.search)
        #expect(window.makeFirstResponder(search))
        let editor = try #require(search.currentEditor() as? NSTextView)
        #expect(content.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        model.revision += 1
        model.search?.value = "op"
        content.update(model)
        #expect(!content.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))),
                "with text, Left moves the caret")
        #expect(values == ["next"])
    }

    @Test func highlightedRailTabTakesReturn() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        var model = Self.model(.symbols)
        model.highlighted = "add"
        var picked: [String?] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        content.update(model)
        #expect(Self.tabs(content).first { $0.row.id == "add" }?.isHighlighted == true)
        #expect(content.handleKey(36))
        #expect(picked == ["add"])
    }

    /// Review finding on #27140: an effort-slider update rebuilt the popup and removed the
    /// `NSSlider` AppKit was tracking after the first drag step.
    @Test func anUpdateDuringASliderDragWaitsForTheRelease() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        let stops = NativePopupSlider(stops: [NativePopupSliderStop(value: "low", label: "Low"), NativePopupSliderStop(value: "high", label: "High")])
        var model = Self.model(.symbols)
        model.rows.append(NativePopupRow(id: "effort", kind: .slider, label: "Effort", value: "0", minimum: 0, maximum: 1, step: 1, slider: stops))
        content.update(model)
        let dragged = try #require(content.rowView(id: "effort") as? NativePopupSliderView)
        var next = model
        next.revision += 1
        next.rows[0].label = "Opus High"
        next.rows[1].value = "1"
        dragged.slider.interact {
            content.update(next)
            #expect(content.rowView(id: "effort") === dragged && dragged.superview === content,
                    "the tracked slider stays in place mid-drag")
            #expect(content.model?.rows[0].label == "Model")
        }
        #expect(content.model?.rows[0].label == "Opus High", "the deferred update lands on release")
        #expect(content.rowView(id: "effort") !== dragged)
    }

    /// A model row with its effort levels: Return picks the model, Right or its side item opens the
    /// levels beside it, and its trailing column reads effort, star, then the key.
    @Test func actionRowWithLevelsOpensThemBesideIt() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        var model = Self.model(.symbols)
        model.rows[0].sideLabel = "Medium"
        model.rows[0].actions = [NativePopupAction(id: "star", label: "☆", keepOpen: true)]
        model.rows[0].children = [NativePopupRow(id: "low", kind: .action, label: "Low"),
                                  NativePopupRow(id: "medium", kind: .action, label: "Medium", checked: true)]
        #expect(model.isValid)
        var picked: [String?] = []
        var opened: [String] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        content.openSubmenu = { row, _ in opened.append(row.id) }
        content.update(model)
        #expect(content.handleKey(124) && opened == ["model"] && picked.isEmpty)
        #expect(content.handleKey(36) && picked == ["model"])
        let row = try #require(content.rowView(id: "model") as? PopupRowView)
        let stack = try #require(row.trailingView as? NSStackView)
        let titles = stack.arrangedSubviews.map { ($0 as? NSButton)?.title ?? ($0 as? ThemedLabel)?.stringValue }
        #expect(titles == ["Medium ›", "☆", "⌘1"])
        (stack.arrangedSubviews.first as? NSButton)?.performClick(nil)
        #expect(opened == ["model", "model"] && picked == ["model"])
        var bad = model
        bad.rows[0].children = nil
        #expect(!bad.isValid, "a side label belongs to a row that opens children")
    }

    private static func tabs(_ content: NSView) -> [NativePopupRailTab] {
        content.subviews.flatMap { view -> [NativePopupRailTab] in
            (view as? NativePopupRailTab).map { [$0] } ?? tabs(view)
        }
    }

    private static func model(_ placement: NativePopupRailPlacement, tabs count: Int = 3) -> NativePopupModel {
        var rail = (0 ..< count).map { index in
            NativePopupRow(id: "tab-\(index)", kind: .action, label: "Tab \(index)", checked: index == 1,
                           mark: index == 0 ? "claude" : nil, monogram: index == 0 ? nil : "T")
        }
        rail.append(NativePopupRow(id: "add", kind: .action, label: "Add harness", icon: "action.add"))
        return NativePopupModel(schemaVersion: 1, id: "picker", revision: 1,
                                anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                side: .bottom, align: .start, width: 320,
                                rows: [NativePopupRow(id: "model", kind: .action, label: "Model", shortcut: "⌘1")],
                                rail: rail, railPlacement: placement)
    }
}
