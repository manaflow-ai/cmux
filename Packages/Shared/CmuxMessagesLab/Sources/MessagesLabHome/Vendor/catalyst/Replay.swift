import Foundation

/// The recording's input, fed into the same engine as live use: the fixture
/// as the initial state, keystrokes at their measured times, Return at the
/// send time, and a scripted responder for Instinct.
enum Replay {
    static let base = Instant.parse("2026-09-30T12:06:05-07:00")
    static let sendTime = 4.6247

    static func makeStore() -> Store {
        let store = Store(conversation: Fixtures.loadConversation(), baseDate: base)
        let responder = ScriptedResponder()
        store.responder = responder
        store.dispatch(.setDraft("How are you doing?\nS"))
        for (t, text) in keystrokes { store.schedule(.setDraft(text), at: t - 0.006) }
        store.schedule(.send, at: sendTime)
        responder.start(store)
        return store
    }

    /// (time the change first shows, full draft text).
    static let keystrokes: [(Double, String)] = {
        let first = "How are you doing?\n"
        let line2 = "Some multiline text..."
        let times2: [Double] = [0.0583, 0.1667, 0.1833, 0.2333, 0.30, 0.4667, 0.50, 0.6167, 0.7167, 0.8667,
                                0.9333, 0.9833, 1.0583, 1.1167, 1.2833, 1.3667, 1.5167, 1.65, 1.75, 1.8833, 2.0]
        var out: [(Double, String)] = []
        for (i, t) in times2.enumerated() { out.append((t, first + String(line2.prefix(i + 2)))) }
        let base = first + line2 + "\n"
        out.append((2.2, base))
        out.append((2.6417, base + "V"))
        out.append((2.9167, base))
        let line3 = "Very cool"
        let times3: [Double] = [3.2, 3.40, 3.55, 3.6833, 3.7333, 3.85, 3.9333, 4.0167, 4.1667]
        for (i, t) in times3.enumerated() { out.append((t, base + String(line3.prefix(i + 1)))) }
        return out
    }()
}

/// Instinct as recorded: an unprompted thread reply to "hello world", then the
/// receipts, typing indicator and threaded answer for the message I send.
final class ScriptedResponder: Responder {
    let instinct = "instinct"

    func start(_ store: Store) {
        store.schedule(.typing(instinct, true), at: 1.2624)
        let hello = Message(id: "r-hello", senderId: instinct, sentAt: Instant.format(store.date(at: 2.39)),
                            parts: [.text("Hello! Still can't see Austin's inbox until Google is reconnected. Want me to resend that link?",
                                          runs: [])],
                            replyTo: PartRef(messageId: "hello", partIndex: 0), status: nil, edits: nil, retractedAt: nil, reactions: [])
        store.schedule(.receive(hello), at: 2.39)
    }

    func didSend(_ m: Message, _ store: Store) {
        let t = store.now
        store.schedule(.status(m.id, .sent), at: t)
        store.schedule(.status(m.id, .delivered(at: Instant.format(store.date(at: 5.6658)))), at: 5.6658)
        store.schedule(.status(m.id, .read(at: Instant.format(store.date(at: 6.602)))), at: 6.602)
        store.schedule(.typing(instinct, true), at: 8.9699)
        let reply = Message(id: "r-doing", senderId: instinct, sentAt: Instant.format(store.date(at: 10.5667)),
                            parts: [.text("Doing well, and the multiline renders nicely. Looks like you're testing something. Anything you want me to do with it?",
                                          runs: [])],
                            replyTo: PartRef(messageId: m.id, partIndex: 0), status: nil, edits: nil, retractedAt: nil, reactions: [])
        store.schedule(.receive(reply), at: 10.5667)
    }
}
