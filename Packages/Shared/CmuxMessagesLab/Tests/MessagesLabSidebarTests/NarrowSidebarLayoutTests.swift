import AppKit
import Testing
@testable import MessagesLabSidebar

/// NARROW LIST (the user, 2026-11-03, msg 20149, two shots: Home's narrow chat list clipped its search
/// field to "Searc" and its "No Results" text). As in Messages' narrow sidebar the list is one column of
/// big round avatars (a group's avatar is its members' faces in one disc) with the name centered under
/// each and truncated, and nothing in the header or the empty list is clipped. These tests lay out real
/// rows and pinned tiles at narrow widths, 1:1 and group chats, read and unread, short and long names.
@MainActor
@Suite(.serialized)
struct NarrowSidebarLayoutTests {
    /// The narrow (avatar-only) widths: the list's minimum and the widest narrow width.
    private static let widths: [CGFloat] = [SidebarMetrics.minimumWidth, 100, 140, SidebarMetrics.compactBelow - 1]
    /// Messages' narrow list: avatars at least this big (the wide list's row avatar is 40 pt).
    private static let bigAvatar: CGFloat = 52
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
        let avatar = l.avatar.frame, name = l.content.frame
        // The layer's frame is in document coordinates: the list's middle in the layer's.
        let middle = width / 2 - l.frame.minX
        #expect(avatar.width >= Self.bigAvatar, "\(context): avatar \(avatar.width) pt, at least \(Self.bigAvatar)")
        #expect(abs(avatar.midX - middle) <= 1, "\(context): avatar \(avatar) centered on \(middle)")
        #expect(l.bounds.contains(avatar), "\(context): avatar \(avatar) inside \(l.bounds)")
        #expect(!l.content.isHidden && l.content.contents != nil, "\(context): the name shows under the avatar")
        #expect(name.minY >= avatar.maxY, "\(context): name \(name) under avatar \(avatar)")
        #expect(l.bounds.contains(name), "\(context): name \(name) inside \(l.bounds) (truncated, not clipped)")
        let lead = l.dot.isHidden ? name.minX : l.dot.frame.minX
        #expect(abs((lead + name.maxX) / 2 - middle) <= 1.5, "\(context): name (and its dot) centered on \(middle)")
        if !l.dot.isHidden {
            #expect(!l.dot.frame.intersects(avatar) && !l.dot.frame.intersects(name), "\(context): the unread dot touches nothing")
        }
    }

    @Test(arguments: [false, true])
    func theNarrowListIsOneColumnOfBigAvatarsWithNamesUnder(pinned: Bool) {
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

    /// A search field too narrow for its placeholder shows only the magnifier, never "Searc".
    @Test(arguments: [56, 64, 200] as [CGFloat])
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
        let room = (s.cell as? NSSearchFieldCell)?.searchTextRect(forBounds: s.bounds).width ?? s.bounds.width
        let needed = (placeholder as NSString).size(withAttributes: [.font: s.font ?? NSFont.systemFont(ofSize: 13)]).width
        #expect(placeholder.isEmpty || needed <= room, "field \(field): placeholder \"\(placeholder)\" needs \(needed) pt, has \(room)")
        if field >= 200 { #expect(!placeholder.isEmpty, "a wide field says Search") }
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
