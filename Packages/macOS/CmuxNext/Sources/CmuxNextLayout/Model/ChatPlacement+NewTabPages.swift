import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The pure steps of a chat docking with the New Tab pages beside it (#22857): which chat docks,
/// which pages follow it and in what order. The App's ChatColumnPlacement extension runs the moves.
extension ChatColumnPlacement {
    /// The one chat to dock when every other tab is a New Tab page; nil for any other mix.
    public nonisolated static func loneChat<Tab>(in tabs: [Tab], isChat: (Tab) -> Bool, isNewTabPage: (Tab) -> Bool) -> Tab? {
        var chat: Tab?
        for tab in tabs {
            if isNewTabPage(tab) { continue }
            guard chat == nil, isChat(tab) else { return nil }
            chat = tab
        }
        return chat
    }

    /// The New Tab pages that follow a docking chat, in their original relative order.
    public nonisolated static func newTabPages<Tab>(in tabs: [Tab], isNewTabPage: (Tab) -> Bool) -> [Tab] {
        tabs.filter(isNewTabPage)
    }

    /// The order of a dock's follow-up: `seed` the new dock's selection (always: nothing newer can
    /// be in a dock that just appeared), `prepare` focus while the run's own intent is current, then
    /// move each page after the chat, rechecking the dock between awaits. A page the person selected
    /// after the run began stays where they are working. A failed move leaves its slot to the next.
    /// `start` is the focus generation when the run began; `prepare`'s own focus change moves it on,
    /// so the generation after `prepare` is the run's, and only a later one is the person's.
    @MainActor public static func followNewTabPages<Page>(_ pages: [Page], start: UInt64, generation: @MainActor () -> UInt64,
                                                   isDockCurrent: @MainActor () -> Bool, seed: @MainActor () -> Void,
                                                   prepare: @MainActor () -> Void, isChosen: @MainActor (Page) -> Bool,
                                                   move: @MainActor (Page, Int) async -> Bool) async {
        guard isDockCurrent() else { return }
        seed()
        var expected = start
        if generation() == expected {
            prepare()
            expected = generation()
        }
        var index = 1
        for page in pages {
            guard isDockCurrent() else { return }
            if generation() != expected, isChosen(page) { continue }
            if await move(page, index) { index += 1 }
        }
    }

    /// A bounded event-driven wait: true once `ready` holds, false past `limit`.
    @MainActor public static func waitForDockUpdate(limit: Duration, _ ready: @escaping @MainActor () -> Bool) async -> Bool {
        let listed = Task { @MainActor () -> Bool in
            for await found in ObservationStream(ready) where found { return true }
            return false
        }
        let bound = DemandTimer(owner: "ChatColumnPlacement.newTabPages")
        bound.schedule(after: limit) { @MainActor in listed.cancel() }
        let found = await listed.value
        bound.cancel()
        return found
    }
}
