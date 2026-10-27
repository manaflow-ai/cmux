import CmuxHomeCore
import Foundation
import QuartzCore
import Testing
@testable import CmuxHomeRender

/// A ``LoopHost`` whose window a test occludes and shows, as the Mac's `LoopVisibility` follows
/// its view's window (p14-energy-115).
@MainActor final class FakeWindowLoopHost: LoopHost {
    private struct Entry {
        weak var layer: CALayer?
        let key: String
        let make: @MainActor () -> CAAnimation?
    }

    private var entries: [Entry] = []
    private(set) var isVisible = true

    func attach(_ layer: CALayer, key: String, make: @escaping @MainActor () -> CAAnimation?) {
        entries.removeAll { $0.layer == nil || ($0.layer === layer && $0.key == key) }
        entries.append(Entry(layer: layer, key: key, make: make))
        layer.removeAnimation(forKey: key)
        if isVisible, let loop = make() { layer.add(loop, forKey: key) }
    }

    func detach(_ layer: CALayer, key: String) {
        entries.removeAll { $0.layer == nil || ($0.layer === layer && $0.key == key) }
        layer.removeAnimation(forKey: key)
    }

    func detachAll() {
        for entry in entries { entry.layer?.removeAnimation(forKey: entry.key) }
        entries.removeAll()
    }

    /// The window is occluded (false) or shows again (true).
    func setVisible(_ visible: Bool) {
        isVisible = visible
        for entry in entries {
            guard let layer = entry.layer else { continue }
            if visible, let loop = entry.make() { layer.add(loop, forKey: entry.key) } else { layer.removeAnimation(forKey: entry.key) }
        }
    }

    /// The keys attached, running or waiting to show.
    var attachedKeys: [String] { entries.filter { $0.layer != nil }.map(\.key).sorted() }

    /// The loops under `key` that are on their layers now.
    func running(_ key: String) -> Int {
        entries.filter { $0.key == key && $0.layer?.animation(forKey: key) != nil }.count
    }
}

/// Home's loops (the caret's blink, the typing dots) run through the host's ``LoopHost``: an
/// occluded window keeps none of them on its layers, and each comes back when it shows.
@MainActor
@Suite struct LoopHostTests {
    private func controller(_ host: FakeWindowLoopHost) -> HomeController {
        let c = HomeController(conversation: Fixtures.conversation, me: Fixtures.me, palette: Fixtures.palette, deadline: ManualDeadline(),
                               calendar: Fixtures.calendar, locale: Locale(identifier: "en_US"), loops: host,
                               now: { Fixtures.start.addingTimeInterval(3600) })
        c.resize(to: CGSize(width: 628, height: 900))
        return c
    }

    @Test func homesLoopsComeOffWhileItsWindowIsOccludedAndComeBack() {
        let host = FakeWindowLoopHost()
        let c = controller(host)
        c.update(items: Fixtures.items(Fixtures.conversation(4)), summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        let caret = c.scene.compose.caret
        #expect(caret.animation(forKey: Animate.caretBlinkKey) != nil, "the caret does not blink")
        let dots = host.running(Animate.typingDotKey)
        #expect(dots == 3, "the typing row's three dots do not pulse: \(dots)")

        host.setVisible(false)
        #expect(caret.animation(forKey: Animate.caretBlinkKey) == nil, "an occluded window's caret blinks")
        #expect(host.running(Animate.typingDotKey) == 0, "an occluded window's typing dots pulse")

        host.setVisible(true)
        #expect(caret.animation(forKey: Animate.caretBlinkKey) != nil, "the caret does not blink again when the window shows")
        #expect(host.running(Animate.typingDotKey) == dots, "the typing dots do not come back when the window shows")
    }

    /// The typing row ending while the window is occluded detaches its dots, so showing the window
    /// does not put a pulse back on a row that no longer types.
    @Test func typingThatEndsWhileOccludedDoesNotComeBack() {
        let host = FakeWindowLoopHost()
        let c = controller(host)
        let items = Fixtures.items(Fixtures.conversation(4))
        c.update(items: items, summary: Fixtures.summary(), typing: [Fixtures.chief], hasOlder: false)
        #expect(host.attachedKeys.contains(Animate.typingDotKey))
        host.setVisible(false)
        c.update(items: items, summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(!host.attachedKeys.contains(Animate.typingDotKey), "the finished typing row's dots stay attached")
        host.setVisible(true)
        #expect(host.running(Animate.typingDotKey) == 0, "a pulse came back on a row that no longer types")
    }

    /// The speed off detaches the blink: an occluded then shown window brings no blink back.
    @Test func theCaretBlinkStaysOffOnceTheSpeedIsOff() {
        let host = FakeWindowLoopHost()
        let c = controller(host)
        c.animationSpeed = .off
        #expect(!host.attachedKeys.contains(Animate.caretBlinkKey))
        host.setVisible(false)
        host.setVisible(true)
        #expect(c.scene.compose.caret.animation(forKey: Animate.caretBlinkKey) == nil)
    }
}
