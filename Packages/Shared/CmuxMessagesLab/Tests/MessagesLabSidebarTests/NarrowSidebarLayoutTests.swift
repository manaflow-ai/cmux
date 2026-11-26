import AppKit
import Testing
@testable import MessagesLabSidebar

/// NARROW LIST (the user, 2026-11-03, msg 20149, two shots: Home's narrow chat list clipped its search
/// field to "Searc" and its "No Results" text). As in Messages' narrow sidebar on macOS 26 (the user,
/// 2026-11-23: "this is too small", their Messages shot) the list is one column of the full rows with
/// the avatar alone, centred: 80.5 pt rows, the 40 pt row avatar, no name, the unread dot where a row
/// has it, and nothing in the header or the empty list is clipped. These tests lay out real rows and
/// pinned tiles at narrow widths, 1:1 and group chats, read and unread, short and long names.
@MainActor
@Suite(.serialized)
struct NarrowSidebarLayoutTests {
    /// The narrow (avatar-only) widths: the list's minimum and the widest narrow width.
    private static let widths: [CGFloat] = [SidebarMetrics.minimumWidth, 100, 140, SidebarMetrics.compactBelow - 1]
    private static let names = ["Al", "Instinct", "Maximilian-Alexander Featherstonehaugh", "Design Review Group Name Long"]

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let view: CmuxSidebarView
        var controller: SidebarController { view.controller }

        init(width: CGFloat, pinned: Bool) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 1200))
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var list: [CmuxSidebarEntry] = []
            for (i, name) in NarrowSidebarLayoutTests.names.enumerated() {
                for unread in [0, 1] {
                    let group = i == 3
                    let people: [CmuxSidebarEntry.Person] = group
                        ? (0..<3).map { .init(id: "p\(i)-\($0)", name: "Person \($0)", initials: "P\($0)") }
                        : [.init(id: "p\(i)", name: name, initials: String(name.prefix(2)).uppercased())]
                    list.append(CmuxSidebarEntry(id: "c\(i)-\(unread)", title: name, people: people, preview: "hello",
                                                 previewSender: group ? "Person 0" : nil,
                                                 lastAt: now.addingTimeInterval(-Double(list.count) * 60), unreadCount: unread, pinned: pinned))
                }
            }
            window.contentView = view
            view.show(list, pinned: pinned ? list.map(\.id) : [])
            view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.document.layoutSubtreeIfNeeded()
            controller.tile(force: true)
        }

        var layers: [SidebarRowLayer] { controller.tileLayers + controller.rowLayers.values.filter { !$0.isHidden } }
    }

    private func check(_ l: SidebarRowLayer, width: CGFloat, _ context: String) {
        let avatar = l.avatar.frame
        // The layer's frame is in document coordinates: the list's middle in the layer's.
        let middle = width / 2 - l.frame.minX
        // cmux: the strip scales with its width (the narrowest list zoomed).
        let m = SidebarMetrics(width: width)
        #expect(avatar.width == m.compactAvatar, "\(context): avatar \(avatar.width) pt, the strip's \(m.compactAvatar)")
        #expect(abs(avatar.midX - middle) <= 1, "\(context): avatar \(avatar) centered on \(middle)")
        #expect(abs(avatar.midY - l.bounds.midY) <= 0.5, "\(context): avatar \(avatar) centred on the row")
        #expect(l.frame.height == m.listRowHeight, "\(context): row \(l.frame.height) pt, the strip's \(m.listRowHeight)")
        #expect(l.content.isHidden, "\(context): a name shows in the narrow list")
        if !l.dot.isHidden {
            #expect(!l.dot.frame.intersects(avatar), "\(context): the unread dot touches the avatar")
            #expect(l.bounds.contains(l.dot.frame), "\(context): the unread dot is clipped")
            #expect(abs(l.dot.frame.midY - l.bounds.midY) <= 0.5, "\(context): the unread dot is off the row's middle")
        }
    }

    @Test(arguments: [false, true])
    func theNarrowListIsOneColumnOfAvatarRows(pinned: Bool) {
        for w in Self.widths {
            let f = Fixture(width: w, pinned: pinned)
            let layers = f.layers
            #expect(layers.count >= 4, "width \(w): rows on screen")
            for l in layers { check(l, width: w, "width \(w), \(pinned ? "pinned" : "row") \(l.conversationID ?? "?")") }
            // One column, no overlap.
            let frames = layers.map(\.frame).sorted { $0.minY < $1.minY }
            for (a, b) in zip(frames, frames.dropFirst()) { #expect(a.maxY <= b.minY + 0.5, "width \(w): \(a) and \(b) overlap") }
        }
    }

    /// A search field too narrow for its placeholder shows only the magnifier, never "Searc", and the
    /// text never starts under the magnifier (the user, 2026-11-23: "Searc" drawn through it).
    @Test(arguments: [40, 48, 56, 64, 72, 200] as [CGFloat])
    func theSearchPlaceholderIsWholeOrNotShown(field: CGFloat) {
        let f = Fixture(width: 76, pinned: false)
        f.controller.headerLayout = { _ in
            f.controller.searchField.frame = CGRect(x: 10, y: 10, width: field, height: 30)
            return 52
        }
        f.view.frame.size.width = max(76, field + 20)
        f.window.setContentSize(f.view.frame.size)
        f.controller.view.layoutSubtreeIfNeeded()
        f.controller.layout(in: f.controller.view.bounds)
        let s = f.controller.searchField
        let placeholder = s.placeholderString ?? ""
        let cell = s.cell as? NSSearchFieldCell
        let room = cell?.searchTextRect(forBounds: s.bounds).width ?? s.bounds.width
        if let cell {
            let text = cell.searchTextRect(forBounds: s.bounds), icon = cell.searchButtonRect(forBounds: s.bounds)
            #expect(text.minX >= icon.maxX - 1, "field \(field): the text starts at \(text.minX), under the magnifier ending at \(icon.maxX)")
        }
        let needed = (placeholder as NSString).size(withAttributes: [.font: s.font ?? NSFont.systemFont(ofSize: 13)]).width
        #expect(placeholder.isEmpty || needed <= room, "field \(field): placeholder \"\(placeholder)\" needs \(needed) pt, has \(room)")
        if field >= 200 { #expect(!placeholder.isEmpty, "a wide field says Search") }
    }

    /// The field takes the keyboard in a wide frame and then narrows (the avatar-only list's open
    /// search): nothing of "Search" stays drawn beside the magnifier (the user, 2026-11-23: an "S"
    /// after the caret). A nil placeholder set while the field edits left the editor drawing it.
    @Test(arguments: [false, true])
    func aFieldThatNarrowsWhileEditingDrawsNoPlaceholder(attributed: Bool) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = root
        let field = CmuxSidebarSearchField(frame: NSRect(x: 10, y: 10, width: 280, height: 16))
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        root.addSubview(field)
        field.placeholderString = SidebarStrings.search
        if attributed {
            field.placeholderAttributedString = NSAttributedString(string: SidebarStrings.search,
                                                                   attributes: [.foregroundColor: NSColor.gray, .font: NSFont.systemFont(ofSize: 13)])
        }
        #expect(window.makeFirstResponder(field))
        field.frame.size.width = 56
        root.layoutSubtreeIfNeeded()
        let rep = try #require(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / field.bounds.width
        let icon = try #require(field.cell as? NSSearchFieldCell).searchButtonRect(forBounds: field.bounds)
        var ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in Int((icon.maxX + 1) * scale)..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { ink += 1 }
        }
        #expect(ink == 0, "\(ink) px of placeholder drawn right of the magnifier in a 56 pt field")
        // Wide again, the placeholder comes back.
        field.frame.size.width = 280
        #expect(field.placeholderAttributedString?.string == SidebarStrings.search || field.placeholderString == SidebarStrings.search)
    }

    /// A narrow field has no clear button over its typed text (the user, 2026-11-23); a wide one
    /// gets it back.
    @Test func aNarrowFieldHidesItsClearButton() throws {
        let field = CmuxSidebarSearchField(frame: NSRect(x: 0, y: 0, width: 280, height: 16))
        field.isBezeled = false
        let cell = try #require(field.cell as? NSSearchFieldCell)
        #expect(cell.cancelButtonCell != nil)
        field.frame.size.width = 56
        #expect(cell.cancelButtonCell == nil, "a 56 pt field keeps its clear button")
        field.stringValue = "chief"
        let text = cell.searchTextRect(forBounds: field.bounds)
        #expect(text.maxX > 56 - 19, "the text keeps the clear button's room")
        field.frame.size.width = CmuxSidebarSearchField.cancelMinimumWidth
        #expect(cell.cancelButtonCell != nil, "a wide field lost its clear button")
    }

    /// "No Results" (and "No Unread") in the narrowest list: the text is never cut. When one line does not
    /// fit, the label wraps word by word onto at most its allowed lines, and every line fits the frame.
    /// (A label that does not wrap reports a size clamped to its frame, so its cell size proves nothing:
    /// this measures the text itself.)
    @Test func theEmptyListTextFitsTheNarrowList() throws {
        let f = Fixture(width: SidebarMetrics.minimumWidth, pinned: false)
        let label = f.controller.noResults
        let font = try #require(label.font)
        for text in [SidebarStrings.noResults, SidebarStrings.noUnread] {
            label.stringValue = text
            f.controller.layout(in: f.controller.view.bounds)
            let frame = label.frame
            let room = frame.width - 4 // the cell's own text inset
            let oneLine = (text as NSString).size(withAttributes: [.font: font]).width
            for word in text.split(separator: " ") {
                let w = (String(word) as NSString).size(withAttributes: [.font: font]).width
                #expect(w <= room, "\"\(word)\" (\(w) pt) is wider than the list's \(room) pt")
            }
            guard oneLine > room else { continue }
            #expect(label.cell?.wraps == true, "\"\(text)\" needs \(oneLine) pt on one line, has \(room): it must wrap, not be cut")
            let wrapped = (text as NSString).boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let lines = Int((wrapped.height / lineHeight).rounded(.up))
            #expect(label.maximumNumberOfLines == 0 || lines <= label.maximumNumberOfLines,
                    "\"\(text)\" needs \(lines) lines, the label shows \(label.maximumNumberOfLines)")
            #expect(wrapped.height <= frame.height + 0.5, "\"\(text)\" needs \(wrapped.height) pt high, has \(frame.height)")
        }
    }
}
