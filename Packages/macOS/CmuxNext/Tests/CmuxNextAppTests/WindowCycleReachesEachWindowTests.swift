import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import CmuxNextDesign
import Testing

/// Select Next Window and Select Previous Window reach each cmux window: with three windows, three presses make
/// three different windows key, and Previous undoes Next.
///
/// The test keeps its own window list (`Desk`): a press asks `WindowTargeting` for the window and then makes that
/// window key and frontmost, which is what the action does with it (`WindowActivation.show(_, .focus)`). The
/// windows are never ordered in. The list is a model of AppKit's order, not AppKit's order itself.
@MainActor @Suite(.serialized, .closesItsWindows) struct WindowCycleReachesEachWindowTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor struct Desk {
        /// The cmux windows in the order they were opened.
        var shells: [NSWindow]
        /// The windows front to back.
        var ordered: [NSWindow]
        var key: NSWindow?

        /// One press of Select Next Window (`offset` 1) or Select Previous Window (-1): the window it makes key.
        mutating func press(_ offset: Int) -> NSWindow? {
            guard let next = WindowTargeting(keyWindow: key, ordered: ordered, shells: shells).cycled(offset) else { return nil }
            ordered.removeAll { $0 === next }
            ordered.insert(next, at: 0)
            key = next
            return next
        }

        /// `count` presses: the window each one makes key.
        mutating func presses(_ offset: Int, count: Int) -> [NSWindow] {
            var keys: [NSWindow] = []
            for _ in 0 ..< count {
                if let next = press(offset) { keys.append(next) }
            }
            return keys
        }

        /// The letters of `windows` by the order they were opened, for a failure text.
        func names(_ windows: [NSWindow]) -> String {
            let letters = ["a", "b", "c"]
            var text: [String] = []
            for window in windows {
                let index = shells.firstIndex { $0 === window }
                text.append(index.map { letters[$0] } ?? "none")
            }
            return text.joined(separator: " ")
        }
    }

    /// Each start: the frontmost window is key, the 2 others are behind it.
    static func starts(_ a: NSWindow, _ b: NSWindow, _ c: NSWindow) -> [[NSWindow]] {
        [[a, b, c], [a, c, b], [b, c, a], [c, a, b]]
    }

    @Test func threePressesOfNextMakeThreeDifferentWindowsKey() {
        let a = Self.window(), b = Self.window(), c = Self.window()
        defer { for window in [a, b, c] { window.close() } }
        for ordered in Self.starts(a, b, c) {
            var desk = Desk(shells: [a, b, c], ordered: ordered, key: ordered[0])
            let keys = desk.presses(1, count: 3)
            let different = Set(keys.map { ObjectIdentifier($0) }).count
            #expect(different == 3, "from \(desk.names(ordered)), three presses of Next made these windows key: \(desk.names(keys))")
            let last: NSWindow? = keys.last
            #expect(last === ordered[0], "from \(desk.names(ordered)), the third press of Next does not come back to the first window")
        }
    }

    @Test func threePressesOfPreviousMakeThreeDifferentWindowsKey() {
        let a = Self.window(), b = Self.window(), c = Self.window()
        defer { for window in [a, b, c] { window.close() } }
        for ordered in Self.starts(a, b, c) {
            var desk = Desk(shells: [a, b, c], ordered: ordered, key: ordered[0])
            let keys = desk.presses(-1, count: 3)
            let different = Set(keys.map { ObjectIdentifier($0) }).count
            #expect(different == 3, "from \(desk.names(ordered)), three presses of Previous made these windows key: \(desk.names(keys))")
            let last: NSWindow? = keys.last
            #expect(last === ordered[0], "from \(desk.names(ordered)), the third press of Previous does not come back to the first window")
        }
    }

    @Test func previousUndoesNext() {
        let a = Self.window(), b = Self.window(), c = Self.window()
        defer { for window in [a, b, c] { window.close() } }
        for ordered in Self.starts(a, b, c) {
            var desk = Desk(shells: [a, b, c], ordered: ordered, key: ordered[0])
            _ = desk.press(1)
            let back = desk.press(-1)
            #expect(back === ordered[0], "from \(desk.names(ordered)), Next then Previous does not come back to the first window")
            _ = desk.press(-1)
            let again = desk.press(1)
            #expect(again === ordered[0], "from \(desk.names(ordered)), Previous then Next does not come back to the first window")
        }
    }

    @Test func oneWindowHasNothingToSelectAndTwoWindowsTrade() {
        let a = Self.window(), b = Self.window()
        defer { for window in [a, b] { window.close() } }
        var one = Desk(shells: [a], ordered: [a], key: a)
        let none = one.press(1)
        #expect(none == nil)
        var two = Desk(shells: [a, b], ordered: [a, b], key: a)
        let keys = two.presses(1, count: 2) + two.presses(-1, count: 1)
        #expect(two.names(keys) == "b a b")
    }
}
