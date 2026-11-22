@testable import CmuxNextDesign
import Testing

/// R96: every cmux dialog answers keys the same way.
struct CmuxDialogKeysTests {
    static let save = CmuxDialogSpec(title: "Save changes?", buttons: [
        CmuxDialogButton(id: "dont-save", title: "Don't Save", role: .destructive, key: "d"),
        .cancel(),
        CmuxDialogButton(id: "save", title: "Save", role: .default),
    ])

    static func action(_ key: CmuxDialogKeys.Key, _ modifiers: CmuxDialogKeys.Modifiers = [],
                       _ spec: CmuxDialogSpec = save) -> CmuxDialogKeys.Action? {
        CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec)
    }

    @Test func returnPressesTheDefaultButton() {
        #expect(Self.action(.return) == .press("save"))
        #expect(Self.action(.return, .command) == .press("save"))
        #expect(Self.action(.return, .option) == nil, "Option-Return is left to the field")
    }

    @Test func returnDoesNothingWithoutADefault() {
        let spec = CmuxDialogSpec(title: "Delete?", buttons: [
            CmuxDialogButton(id: "delete", title: "Delete", role: .destructive), .cancel(),
        ])
        #expect(Self.action(.return, [], spec) == nil)
    }

    @Test func escapeAndCommandPeriodPressCancel() {
        #expect(Self.action(.escape) == .press("cancel"))
        #expect(Self.action(.character("."), .command) == .press("cancel"))
    }

    @Test func escapeOnAOneButtonDialogPressesThatButton() {
        let spec = CmuxDialogSpec(title: "Done", buttons: [.ok()])
        #expect(Self.action(.escape, [], spec) == .press("ok"))
    }

    @Test func commandAndAButtonKeyPressThatButton() {
        #expect(Self.action(.character("d"), .command) == .press("dont-save"))
        #expect(Self.action(.character("D"), [.command, .shift]) == .press("dont-save"))
        #expect(Self.action(.character("d")) == nil, "a plain letter types into the field")
        #expect(Self.action(.character("x"), .command) == nil)
    }

    @Test func tabMovesFocusInsideTheDialog() {
        #expect(Self.action(.tab) == .focusNext)
        #expect(Self.action(.tab, .shift) == .focusPrevious)
        #expect(Self.action(.tab, .control) == nil)
    }

    @Test func focusWrapsAtBothEnds() {
        #expect(CmuxDialogKeys.focus(after: nil, count: 3, backward: false) == 0)
        #expect(CmuxDialogKeys.focus(after: nil, count: 3, backward: true) == 2)
        #expect(CmuxDialogKeys.focus(after: 2, count: 3, backward: false) == 0)
        #expect(CmuxDialogKeys.focus(after: 0, count: 3, backward: true) == 2)
        #expect(CmuxDialogKeys.focus(after: 1, count: 3, backward: false) == 2)
        #expect(CmuxDialogKeys.focus(after: 0, count: 0, backward: false) == nil)
    }
}

/// One dialog at a time per scope, in order.
struct CmuxDialogQueueTests {
    @Test func aSecondDialogInTheSameScopeWaits() {
        var queue = CmuxDialogQueue<String>()
        let r1 = queue.enqueue(1, in: "tab-a")
        #expect(r1)
        let r2 = queue.enqueue(2, in: "tab-a")
        #expect(!r2)
        let r3 = queue.enqueue(3, in: "tab-b")
        #expect(r3, "another tab's dialog shows at once")
        #expect(queue.visible(in: "tab-a") == 1)
        let r4 = queue.remove(1)
        #expect(r4 == 2)
        #expect(queue.isVisible(2))
        let r5 = queue.remove(2)
        #expect(r5 == nil)
        #expect(queue.visible(in: "tab-a") == nil)
    }

    @Test func removingAQueuedDialogShowsNothingNew() {
        var queue = CmuxDialogQueue<String>()
        _ = queue.enqueue(1, in: "w")
        _ = queue.enqueue(2, in: "w")
        _ = queue.enqueue(3, in: "w")
        let r6 = queue.remove(2)
        #expect(r6 == nil)
        #expect(queue.ids(in: "w") == [1, 3])
        let r7 = queue.remove(1)
        #expect(r7 == 3)
        let r8 = queue.remove(42)
        #expect(r8 == nil)
    }

    /// Seeded random enqueue/remove runs against a reference model: the
    /// visible dialog of a scope is always its oldest open one.
    @Test func visibleIsAlwaysTheOldestInItsScope() {
        var generator = DialogTestRandom(seed: 96)
        for _ in 0..<200 {
            var queue = CmuxDialogQueue<Int>()
            var model: [(id: Int, scope: Int)] = []
            var next = 1
            for _ in 0..<40 {
                if model.isEmpty || generator.next() % 3 != 0 {
                    let scope = Int(generator.next() % 3)
                    let showsNow = queue.enqueue(next, in: scope)
                    #expect(showsNow == !model.contains { $0.scope == scope })
                    model.append((next, scope))
                    next += 1
                } else {
                    let index = Int(generator.next() % UInt64(model.count))
                    let removed = model.remove(at: index)
                    let wasOldest = !model[..<index].contains { $0.scope == removed.scope }
                    let expected = wasOldest ? model.first { $0.scope == removed.scope }?.id : nil
                    let r9 = queue.remove(removed.id)
                    #expect(r9 == expected)
                }
                for scope in 0..<3 {
                    #expect(queue.visible(in: scope) == model.first { $0.scope == scope }?.id)
                }
            }
        }
    }
}

struct DialogTestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
