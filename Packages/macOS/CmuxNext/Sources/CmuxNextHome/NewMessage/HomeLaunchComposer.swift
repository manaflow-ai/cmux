public import AppKit
public import CmuxHomeCore
import CmuxNextWakeups

/// A bare launch's Chief page (no remembered Chief, nothing listed yet): the app's own Chief view
/// over a provisional Chief (``HomeLaunchChiefSource``, a store of its own), so keys land before
/// the Chief's owner answers and the page is the one the Chief's will be. Its sends wait in
/// ``hold``; ``handOff(to:)`` gives its draft (after the Chief's own) and its sends (in order,
/// each under its own key, once) to the real Chief. Before that, a quit's save step
/// (``saveForQuit()``) and a release keep the held and typed text as Home's draft of the launch
/// conversation, which the next launch's page starts with (or the Chief's, when the next launch
/// has its Chief at once: ``claimParked(to:in:)``): nothing typed is dropped.
@MainActor
public final class HomeLaunchComposer {
    /// The page (the app's Chief view, made by `makeView`).
    public let view: NSView
    public let store: HomeStore
    public let hold: LaunchChiefHold
    /// Home's own store: the Chief's sends and drafts go there.
    private let home: HomeStore
    private static let conversation = HomeLaunchChiefSource.conversation

    /// Makes the page, starting with what a page released before its Chief answered kept.
    /// - Parameters:
    ///   - home: Home's own store.
    ///   - me: The signed-in person when `home` has none yet.
    ///   - title: The header's name (`HomeStrings.chiefName`).
    ///   - column: Where the page goes, filling it (the Messages page's transcript column); nil: nowhere yet.
    ///   - makeView: The app's Chief view over a store and its conversation.
    public init(home: HomeStore, me: Participant, title: String, in column: NSView? = nil, makeView: (HomeStore, ConversationID) -> NSView) {
        let hold = LaunchChiefHold()
        (self.home, self.hold) = (home, hold)
        store = HomeStore(source: HomeLaunchChiefSource(me: home.me ?? me, title: title, hold: hold))
        store.start()
        store.setDraft(home.draft(for: Self.conversation) ?? "", for: Self.conversation)
        home.setDraft("", for: Self.conversation)
        view = makeView(store, Self.conversation)
        guard let column else { return }
        view.frame = column.bounds
        view.autoresizingMask = [.width, .height]
        column.addSubview(view)
    }

    // cx-t7hu: not an isolated deinit; the last reference can go on any thread. The parking and
    // the store's stop are main-actor work, delivered there.
    nonisolated deinit {
        let (store, hold, home) = (store, hold, home)
        MainDelivery().run {
            Self.park(store, hold: hold, in: home)
            store.stop()
        }
    }

    /// A bare launch mounts its page: nothing shown, no New Message page, nothing to open, no Chief
    /// remembered from the last launch (`HomeStore.launchChief`), not classic Home.
    public static func shows(shown: ConversationID?, composing: Bool, defaultConversation: ConversationID?,
                             launchChief: ConversationID?, classic: Bool) -> Bool {
        shown == nil && !composing && defaultConversation == nil && launchChief == nil && !classic
    }

    /// The Chief is `chief` while `shown`, another conversation, replaced the page: the page hands
    /// off and ends (nil). The page itself otherwise (no Chief yet, nothing else shown, or the
    /// Chief shown: ``handOff(to:)`` then runs where the Chief's view is made).
    public func handingOff(toChief chief: String?, showing shown: ConversationID?) -> HomeLaunchComposer? {
        guard let chief, let shown, shown.rawValue != chief else { return self }
        handOff(to: ConversationID(chief))
        end()
        return nil
    }

    /// The window's keyboard is in the page.
    public var holdsKeyboard: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// The real Chief is `chief`: the page's draft goes after the Chief's own and the held sends go
    /// to it through Home's store under their own keys, in order and once. Once; again does nothing.
    public func handOff(to chief: ConversationID) {
        home.setDraft("", for: Self.conversation)  // a quit's save that did not end in a quit: the page has it all
        Self.handOff(store, hold: hold, to: chief, store: home)
    }

    /// The page leaves its column and its store stops (after ``handOff(to:)``).
    public func end() {
        view.removeFromSuperview()
        store.stop()
    }

    /// Quit's save step, before Home's cache is written: the held sends' text, then what was typed,
    /// as Home's draft of the launch conversation. The page goes on as it was (a quit can be cancelled).
    public func saveForQuit() {
        home.setDraft(Self.keptText(store, held: hold.heldParts), for: Self.conversation)
    }

    /// The held sends' text, then the draft of `launch`, a line apart.
    static func keptText(_ launch: HomeStore, held: [[MessagePart]]) -> String {
        [LaunchChiefHold.text(of: held), launch.draft(for: conversation) ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `text` after `id`'s own draft in `store`, on a line of its own; false when there was none.
    @discardableResult
    public static func appendDraft(_ text: String, to id: ConversationID, store: HomeStore) -> Bool {
        guard !text.isEmpty else { return false }
        let own = store.draft(for: id) ?? ""
        store.setDraft(own.isEmpty ? text : own + "\n" + text, for: id)
        return true
    }

    /// The launch's draft goes after `chief`'s own in `store`, and each held send goes to `chief`
    /// through `store` under its original key, in order and once.
    public static func handOff(_ launch: HomeStore, hold: LaunchChiefHold, to chief: ConversationID, store: HomeStore) {
        if appendDraft(launch.draft(for: conversation) ?? "", to: chief, store: store) { launch.setDraft("", for: conversation) }
        hold.resolve(chief) { chief, parts, key in
            // The real store owns the send from here (its offline queue and Not Delivered state).
            _ = try? await store.perform(.sendMessage(conversation: chief, parts: parts), key: key)
        }
    }

    /// What a page released or quit before its Chief answered kept in `home` goes after `chief`'s own
    /// draft (a launch that had its Chief at once mounts no page to take it).
    public static func claimParked(to chief: ConversationID, in home: HomeStore) {
        if appendDraft(home.draft(for: conversation) ?? "", to: chief, store: home) { home.setDraft("", for: conversation) }
    }

    /// Released before the Chief answered: the held sends are refused, and their text, then what was
    /// typed, are kept as `home`'s draft of the launch conversation. After a hand-off nothing is left.
    public static func park(_ launch: HomeStore, hold: LaunchChiefHold, in home: HomeStore) {
        appendDraft(keptText(launch, held: hold.cancel()), to: conversation, store: home)
        launch.setDraft("", for: conversation)
    }
}
