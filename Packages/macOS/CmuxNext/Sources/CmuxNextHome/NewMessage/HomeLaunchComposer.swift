public import AppKit
public import CmuxHomeCore
public import CmuxNextDesign
import CmuxNextWakeups

/// Home's message box over a store of its own that knows one local conversation (New Message's
/// blank page, a bare launch's box): the same composer, glass and send motion as every
/// conversation, text only (attachments upload to a real conversation, which does not exist yet).
@MainActor
public struct HomeLocalComposer: Sendable {
    public let store: HomeStore
    public let view: HomeNativeTranscriptView

    /// Starts the store over `source` and makes the box.
    /// - Parameters:
    ///   - source: The local owner (``HomeNewMessageComposerSource``, ``HomeLaunchChiefSource``).
    ///   - conversation: Its one conversation.
    ///   - me: The signed-in person.
    ///   - draft: The text the box starts with.
    ///   - openPanel: The app's made-ahead open panel.
    ///   - spellChecking: The composer's spell checking setting.
    ///   - identifier: The view's accessibility identifier.
    public init(source: any HomeSource, conversation: ConversationID, me: ParticipantID, draft: String,
                openPanel: MadeAheadOpenPanel?, spellChecking: Bool, identifier: String) {
        store = HomeStore(source: source)
        store.start()
        if !draft.isEmpty { store.setDraft(draft, for: conversation) }
        view = HomeNativeTranscriptView(store: store, conversation: conversation, me: me, openPanel: openPanel)
        view.composerSpellCheckingEnabled = spellChecking
        view.attachmentPreparer = nil
        view.setAccessibilityIdentifier(identifier)
    }

    /// Ends the box and its store (connection, resend and prune tasks; the cache flushed).
    public func stop() {
        view.stop()
        store.stop()
    }
}

/// A bare launch's message box (no remembered Chief, nothing listed yet): mounted over its
/// provisional Chief (``HomeLaunchChiefSource``) so keys land before the Chief's owner answers.
/// Its sends wait in ``hold``; ``handOff(to:)`` gives its draft (after the Chief's own) and its
/// sends (in order, each under its own key, once) to the real Chief. Released before that, the
/// held and typed text is kept as Home's draft of the launch conversation, which the next
/// launch's box starts with: nothing typed is dropped.
@MainActor
public final class HomeLaunchComposer {
    public let view: HomeNativeTranscriptView
    public let store: HomeStore
    public let hold: LaunchChiefHold
    /// Home's own store: the Chief's sends and drafts go there.
    private let home: HomeStore
    private static let conversation = HomeLaunchChiefSource.conversation

    /// Makes the box, starting with what a box released before its Chief answered kept, and
    /// fills `column` with it.
    /// - Parameters:
    ///   - home: Home's own store.
    ///   - me: The signed-in person when `home` has none yet.
    ///   - title: The header's name (`HomeStrings.chiefName`).
    ///   - openPanel: The app's made-ahead open panel.
    ///   - spellChecking: The composer's spell checking setting.
    ///   - column: Where the box goes (the Messages page's transcript column).
    public init(home: HomeStore, me: Participant, title: String, openPanel: MadeAheadOpenPanel?, spellChecking: Bool, in column: NSView) {
        let hold = LaunchChiefHold()
        (self.home, self.hold) = (home, hold)
        let me = home.me ?? me
        let kept = home.draft(for: Self.conversation) ?? ""
        home.setDraft("", for: Self.conversation)
        let box = HomeLocalComposer(source: HomeLaunchChiefSource(me: me, title: title, hold: hold), conversation: Self.conversation,
                                    me: me.id, draft: kept, openPanel: openPanel, spellChecking: spellChecking,
                                    identifier: "cmux.home.launchComposer")
        (view, store) = (box.view, box.store)
        view.frame = column.bounds
        view.autoresizingMask = [.width, .height]
        column.addSubview(view)
    }

    // cx-t7hu: not an isolated deinit; the last reference can go on any thread. The parking and
    // stops are main-actor work, delivered there.
    nonisolated deinit {
        let (view, store, hold, home) = (view, store, hold, home)
        MainDelivery().run {
            Self.park(store, hold: hold, in: home)
            view.stop()
            store.stop()
        }
    }

    /// A bare launch mounts its box: nothing shown, no New Message page, nothing to open, no Chief
    /// remembered from the last launch (`HomeStore.launchChief`), not classic Home.
    public static func shows(shown: ConversationID?, composing: Bool, defaultConversation: ConversationID?,
                             launchChief: ConversationID?, classic: Bool) -> Bool {
        shown == nil && !composing && defaultConversation == nil && launchChief == nil && !classic
    }

    /// The Chief is `chief` while `shown`, another conversation, is over the hidden box: the
    /// box hands off and ends (nil). The box itself otherwise (no Chief yet, nothing else
    /// shown, or the Chief shown: ``handOff(to:)`` then runs where the Chief's view is made).
    public func handingOff(toChief chief: String?, showing shown: ConversationID?) -> HomeLaunchComposer? {
        guard let chief, let shown, shown.rawValue != chief else { return self }
        handOff(to: ConversationID(chief))
        end()
        return nil
    }

    /// The window's keyboard is in the box.
    public var holdsKeyboard: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// The box takes the keyboard. nil when the window refused it; else whether its window is key
    /// (the first time it is, the window is usable).
    public func takeKeyboard(in window: NSWindow?) -> Bool? {
        guard let window, FocusRoute(.system, "Home's launch message box").moveKeyboard(in: window, to: view.primaryInput) else { return nil }
        return window.isKeyWindow
    }

    /// A key typed while Home had the keyboard outside a text input: the box takes it and the key.
    public func beginTyping(with event: NSEvent) {
        guard let window = view.window, FocusRoute(.person, "a key typed into Home").moveKeyboard(in: window, to: view.primaryInput) else { return }
        window.firstResponder?.keyDown(with: event)
    }

    /// Whether Home getting focus moves the keyboard from `responder` to the box: always from
    /// outside `page`; inside the box as its transcript decides; never from the conversation list.
    public func shouldTakeKeyboard(from responder: NSResponder?, page: NSView, list: NSView) -> Bool {
        guard let responder = responder as? NSView, responder === page || responder.isDescendant(of: page) else { return true }
        if responder === view || responder.isDescendant(of: view) { return view.primaryInputShouldTakeKeyboard(from: responder) }
        return !responder.isDescendant(of: list)
    }

    /// The real Chief is `chief`: the box's draft goes after the Chief's own and the held sends go to
    /// it through Home's store under their own keys, in order and once. Once; again does nothing.
    public func handOff(to chief: ConversationID) {
        Self.handOff(store, hold: hold, to: chief, store: home)
    }

    /// The box leaves its column and stops (after ``handOff(to:)``, or with its text parked).
    public func end() {
        view.removeFromSuperview()
        view.stop()
        store.stop()
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

    /// Released before the Chief answered: the held sends' text, then what was typed, are kept as
    /// `home`'s draft of the launch conversation. After a hand-off there is nothing left to keep.
    public static func park(_ launch: HomeStore, hold: LaunchChiefHold, in home: HomeStore) {
        appendDraft(LaunchChiefHold.text(of: hold.cancel()), to: conversation, store: home)
        if appendDraft(launch.draft(for: conversation) ?? "", to: conversation, store: home) { launch.setDraft("", for: conversation) }
    }
}
