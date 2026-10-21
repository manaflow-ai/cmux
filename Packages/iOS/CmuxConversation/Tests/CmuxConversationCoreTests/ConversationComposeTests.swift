import Foundation
import Testing
@testable import CmuxConversationCore

private let kate = ConversationContact(id: "kate", name: "Kate Bell", initials: "KB", colorHex: "#64D2FF", handles: [
    ConversationContactHandle(value: "+1 (555) 564-8583", label: "mobile", service: .iMessage),
])
private let hank = ConversationContact(id: "hank", name: "Hank M. Zakroff", initials: "HZ", colorHex: "#8E8E93", handles: [
    ConversationContactHandle(value: "+1 (555) 766-4823", label: "work", service: .sms),
])

@Suite struct ConversationRecipientDraftTests {
    @Test func backspaceSelectsTheLastTokenThenDeletesItAsAUnit() {
        var draft = ConversationRecipientDraft()
        draft.add(kate)
        draft.add(hank)
        draft.setText("x")
        let r1 = draft.backspace()

        #expect(r1 == false, "with text typed, Backspace deletes a character")
        draft.setText("")
        let r2 = draft.backspace()

        #expect(r2)
        #expect(draft.selectedID == "c:hank")
        #expect(draft.recipients.count == 2, "first Backspace only selects")
        let r3 = draft.backspace()

        #expect(r3)
        #expect(draft.recipients.map(\.id) == ["c:kate"])
        #expect(draft.selectedID == nil)
    }

    @Test func aTappedTokenIsDeletedByBackspaceAndTypingDeselects() {
        var draft = ConversationRecipientDraft()
        draft.add(kate)
        draft.add(hank)
        draft.select("c:kate")
        #expect(draft.selectedID == "c:kate")
        draft.setText("a")
        #expect(draft.selectedID == nil)
        draft.setText("")
        draft.select("c:kate")
        draft.backspace()
        #expect(draft.recipients.map(\.id) == ["c:hank"])
        draft.select("nope")
        #expect(draft.selectedID == nil)
    }

    @Test func addingTheSameContactTwiceKeepsOneToken() {
        var draft = ConversationRecipientDraft()
        let r4 = draft.add(kate)

        #expect(r4)
        draft.setText("Ka")
        let r5 = draft.add(kate)

        #expect(r5 == false)
        #expect(draft.recipients.count == 1)
        #expect(draft.text.isEmpty, "picking clears the query even for a duplicate")
    }

    @Test func typedAddressResolvesToAServiceOrInvalid() {
        var draft = ConversationRecipientDraft()
        draft.setText(" (555) 123-4567 ")
        let token = draft.commitText()
        #expect(token?.state == .resolving)
        #expect(draft.text.isEmpty)
        #expect(draft.canSend == false, "cannot send while looking up")
        #expect(draft.service == nil)
        draft.resolve(ConversationHandleLookup(handle: "(555) 123-4567", service: .sms, contact: nil))
        #expect(draft.recipients[0].state == .resolved(.sms))
        #expect(draft.canSend)
        #expect(draft.service == .sms)

        draft.setText("Apple")
        draft.commitText()
        draft.resolve(ConversationHandleLookup(handle: "Apple", service: nil, contact: nil))
        #expect(draft.recipients[1].state == .invalid)
        #expect(draft.canSend == false)
    }

    @Test func aTypedAddressOfAKnownContactBecomesThatContact() {
        var draft = ConversationRecipientDraft()
        draft.setText("kate-bell@mac.com")
        draft.commitText()
        draft.resolve(ConversationHandleLookup(handle: "kate-bell@mac.com", service: .iMessage, contact: kate))
        #expect(draft.recipients.first?.name == "Kate Bell")
        #expect(draft.recipients.first?.ref == .participant("kate"))
        // Typing the same person again by another address collapses into the existing token.
        draft.setText("+1 (555) 564-8583")
        draft.commitText()
        draft.resolve(ConversationHandleLookup(handle: "+1 (555) 564-8583", service: .iMessage, contact: kate))
        #expect(draft.recipients.count == 1)
    }

    @Test func serviceLineIsSMSWhenAnyRecipientIsSMSOnly() {
        var draft = ConversationRecipientDraft()
        #expect(draft.service == nil)
        draft.add(kate)
        #expect(draft.service == .iMessage)
        draft.add(hank)
        #expect(draft.service == .sms)
        draft.remove("c:hank")
        draft.setText("x@y.co")
        draft.commitText()
        #expect(draft.service == nil, "unknown until every recipient resolves")
    }
}

final class FakeDirectory: ConversationDirectory, @unchecked Sendable {
    let lock = NSLock()
    var searches: [(query: String, excluding: [String])] = []
    var searchDelay: [String: Duration] = [:]
    var created: [[ConversationRecipientRef]] = []
    let contacts = [kate, hank]

    func searchContacts(_ query: String, limit: Int, excluding: [String]) async throws -> [ConversationContact] {
        lock.withLock { searches.append((query, excluding)) }
        if let delay = searchDelay[query] { try await Task.sleep(for: delay) }
        return contacts.filter { !excluding.contains($0.id) && $0.name.lowercased().hasPrefix(query.lowercased()) }
    }

    func lookupHandles(_ handles: [String]) async throws -> [ConversationHandleLookup] {
        handles.map { ConversationHandleLookup(handle: $0, service: $0.contains("@") ? .iMessage : .sms, contact: nil) }
    }

    func createConversation(_ recipients: [ConversationRecipientRef]) async throws -> ConversationCreation {
        lock.withLock { created.append(recipients) }
        let info = ConversationInfo(id: "new_1", title: "Kate Bell", kind: .direct, participants: [])
        return ConversationCreation(info: info, created: true, service: .iMessage)
    }
}

@MainActor
@Suite struct ConversationComposeSessionTests {
    @Test func suggestionsFollowTheNewestQueryOnly() async throws {
        let directory = FakeDirectory()
        directory.searchDelay["k"] = .milliseconds(200)
        let session = ConversationComposeSession(directory: directory)
        session.setText("k")
        session.setText("h")
        try await waitUntil { session.suggestions.map(\.id) == ["hank"] }
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.suggestions.map(\.id) == ["hank"], "the slow 'k' result never replaces the newer 'h' result")
    }

    @Test func returnTakesTheFirstSuggestionAndExcludesItAfterwards() async throws {
        let directory = FakeDirectory()
        let session = ConversationComposeSession(directory: directory)
        session.setText("ka")
        try await waitUntil { !session.suggestions.isEmpty }
        session.commitText()
        #expect(session.draft.recipients.map(\.id) == ["c:kate"])
        #expect(session.suggestions.isEmpty)
        session.setText("k")
        try await waitUntil { directory.lock.withLock { directory.searches.last?.query == "k" } }
        #expect(directory.lock.withLock { directory.searches.last?.excluding } == ["kate"])
    }

    @Test func returnWithoutSuggestionsLooksUpTheTypedAddress() async throws {
        let session = ConversationComposeSession(directory: FakeDirectory())
        session.setText("zed@example.com")
        session.commitText()
        #expect(session.draft.recipients.first?.state == .resolving)
        try await waitUntil { session.draft.recipients.first?.state == .resolved(.iMessage) }
    }

    @Test func firstSendCommitsLeftoverTextAndCreatesWithEveryRecipient() async throws {
        let directory = FakeDirectory()
        let session = ConversationComposeSession(directory: directory)
        session.add(kate)
        session.setText("(555) 123-4567")
        let creation = try await session.openConversation()
        #expect(creation.info.id == "new_1")
        #expect(directory.created == [[.participant("kate"), .handle("(555) 123-4567")]])
        #expect(session.isSending == false)
    }

    @Test func firstSendWithoutRecipientsFails() async {
        let session = ConversationComposeSession(directory: FakeDirectory())
        await #expect(throws: ConversationBackendError.self) { try await session.openConversation() }
    }
}
