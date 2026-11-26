import AppKit
import Testing
@testable import MessagesLabSidebar

/// The user, 2026-11-03 (msg 20105): remove every animation in the Home chat list: rows that move or
/// appear, unread changes, the typing bubble, a Chief's avatar loops and cues, the pin drag and the swipe.
/// Reduce Motion is pinned off here, so only the list's own default stops the motion.
@MainActor
@Suite(.serialized)
struct SidebarListStillTests {
    @MainActor
    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        var entries: [CmuxSidebarEntry]
        var pinned = ["chief"]
        var controller: SidebarController { view.controller }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init() {
            let names = ["Chief", "Austin Wang", "Team", "Unii", "Maya", "Noah"]
            entries = names.enumerated().map { [now] i, name in
                let id = i == 0 ? "chief" : "c\(i)"
                return CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p\(i)", name: name, initials: String(name.prefix(2)).uppercased())],
                                        preview: "message \(i)", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60),
                                        unreadCount: 0, pinned: i == 0, avatar: .monogram(String(name.prefix(2)).uppercased()))
            }
            window.contentView = view
            controller.setWindowActive(true)
            view.onPlacePinned = { [unowned self] id, index in
                pinned.removeAll { $0 == id }
                pinned.insert(id, at: min(index, pinned.count))
                show()
            }
            view.onSetPinned = { [unowned self] pin, id in
                pinned.removeAll { $0 == id }
                if pin { pinned.append(id) }
                show()
            }
            show()
            view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.document.layoutSubtreeIfNeeded()
            controller.tile(force: true)
        }

        func show() {
            for i in entries.indices { entries[i].pinned = pinned.contains(entries[i].id) }
            view.show(entries, pinned: pinned)
            controller.tile(force: true)
        }

        func change(_ id: String, _ edit: (inout CmuxSidebarEntry) -> Void) {
            for i in entries.indices where entries[i].id == id { edit(&entries[i]) }
            show()
        }

        /// Every animation on the list's layers now, as "layer name or conversation: key".
        func animations() -> [String] {
            var out: [String] = []
            var layers: [CALayer] = [controller.document.layer, view.layer].compactMap { $0 }
            if let ghost = controller.pinDragState.ghost { layers.append(ghost) }
            while let l = layers.popLast() {
                let owner = (l as? SidebarRowLayer)?.conversationID ?? l.name ?? String(describing: type(of: l))
                out += (l.animationKeys() ?? []).map { "\(owner): \($0)" }
                layers += l.sublayers ?? []
            }
            return out
        }
    }

    init() { CmuxSidebarView.reduceMotionOverride = false }

    @Test func noChangeToTheListAnimates() throws {
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        let f = Fixture()
        var seen = f.animations()

        // A new message moves a row to the top, with an unread badge and a typing bubble.
        f.change("c4") { $0.lastAt = f.now.addingTimeInterval(60); $0.unreadCount = 1; $0.typing = true }
        seen += f.animations()
        // The typing stops and the row is read.
        f.change("c4") { $0.typing = false; $0.unreadCount = 0 }
        seen += f.animations()

        // A row dragged onto the pinned grid.
        let row = try #require((f.controller.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
            .first { $0.conversationID == "c2" && !$0.isHidden })
        #expect(f.controller.beginPinDrag(at: CGPoint(x: row.frame.minX + 150, y: row.frame.midY)))
        seen += f.animations()
        let tile = f.controller.tileRect(1)
        for i in 0...10 {
            let t = CGFloat(i) / 10
            f.controller.movePinDrag(to: CGPoint(x: 170 + (tile.midX - 170) * t, y: row.frame.midY + (tile.midY - row.frame.midY) * t))
            seen += f.animations()
        }
        f.controller.endPinDrag()
        seen += f.animations()

        #expect(seen.isEmpty, "\(Set(seen).sorted())")
    }
}
