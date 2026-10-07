import Foundation
import Testing
@testable import CmuxConversationCore

@MainActor
@Suite struct ConversationTranslationTests {
    private let english = Locale.Language(identifier: "en")
    private let spanish = Locale.Language(identifier: "es")

    /// "es: hola" is Spanish, "ja: ..." Japanese; anything else is undetected.
    private static func detect(_ text: String) -> Locale.Language? {
        guard let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) == 2 else { return nil }
        return Locale.Language(identifier: String(text[..<colon]))
    }

    private func makeStore(total: Int = 3) async throws -> (ScriptedBackend, ConversationStore, ConversationTranslations, StubTranslator) {
        let backend = ScriptedBackend(total: total)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let translations = ConversationTranslations(store: store, targetLanguage: english, defaults: nil, detect: Self.detect)
        let translator = StubTranslator()
        translations.translator = translator
        return (backend, store, translations, translator)
    }

    private func live(_ backend: ScriptedBackend, _ store: ConversationStore, seq: Int, sender: String, text: String, eventSeq: Int) -> ConversationMessage {
        var message = backend.makeMessage(seq: seq, sender: sender)
        message.text = text
        store.apply(.message(message, eventSeq: eventSeq))
        return message
    }

    @Test func translateThisMessageShowsTranslationAndTogglesOriginal() async throws {
        let (backend, store, translations, _) = try await makeStore()
        let message = live(backend, store, seq: 4, sender: "lc", text: "es: hola", eventSeq: 100)

        #expect(translations.translateMessage(message) == .started)
        #expect(translations.presentation(for: message)?.caption == .translating)
        try await waitUntil { translations.presentation(for: message)?.caption == .showOriginal }
        #expect(translations.presentation(for: message)?.text == "[en] es: hola")

        translations.toggleOriginal(rowID: message.rowID)
        #expect(translations.presentation(for: message)?.text == "es: hola")
        #expect(translations.presentation(for: message)?.caption == .viewTranslation)
        translations.toggleOriginal(rowID: message.rowID)
        #expect(translations.presentation(for: message)?.caption == .showOriginal)
    }

    @Test func undetectedOrSameLanguageAsksForTheSource() async throws {
        let (backend, store, translations, _) = try await makeStore()
        let unknown = live(backend, store, seq: 4, sender: "lc", text: "lol", eventSeq: 100)
        let alreadyEnglish = live(backend, store, seq: 5, sender: "lc", text: "en: hello", eventSeq: 101)
        #expect(translations.translateMessage(unknown) == .needsSourceLanguage)
        #expect(translations.translateMessage(alreadyEnglish) == .needsSourceLanguage)
        #expect(translations.presentation(for: unknown) == nil)

        #expect(translations.translateMessage(unknown, from: spanish) == .started)
        try await waitUntil { translations.presentation(for: unknown)?.caption == .showOriginal }
    }

    @Test func translateConversationCoversOthersInThatLanguageAndLaterArrivals() async throws {
        let (backend, store, translations, translator) = try await makeStore()
        let spanishIncoming = live(backend, store, seq: 4, sender: "lc", text: "es: buenos días", eventSeq: 100)
        let mine = live(backend, store, seq: 5, sender: "me", text: "es: gracias", eventSeq: 101)
        let japanese = live(backend, store, seq: 6, sender: "lc", text: "ja: おはよう", eventSeq: 102)

        #expect(translations.translateConversation(from: spanishIncoming) == .started)
        #expect(translations.indicator == .translating(source: spanish))
        try await waitUntil { translations.isShowingTranslation(rowID: spanishIncoming.rowID) }
        #expect(translations.presentation(for: mine) == nil)
        #expect(translations.presentation(for: japanese) == nil)

        let later = live(backend, store, seq: 7, sender: "lc", text: "es: ¿vienes?", eventSeq: 103)
        try await waitUntil { translations.isShowingTranslation(rowID: later.rowID) }
        #expect(translator.calls.allSatisfy { $0.source == "es" && $0.target == "en" })

        translations.stopTranslating()
        #expect(translations.indicator == nil)
        #expect(translations.presentation(for: spanishIncoming) == nil)
        #expect(translations.presentation(for: later) == nil)
    }

    @Test func stoppingKeepsMessagesTranslatedOneByOne() async throws {
        let (backend, store, translations, _) = try await makeStore()
        let single = live(backend, store, seq: 4, sender: "lc", text: "es: uno", eventSeq: 100)
        let other = live(backend, store, seq: 5, sender: "lc", text: "es: dos", eventSeq: 101)
        translations.translateMessage(single)
        try await waitUntil { translations.isShowingTranslation(rowID: single.rowID) }
        translations.translateConversation(from: other)
        try await waitUntil { translations.isShowingTranslation(rowID: other.rowID) }
        translations.stopTranslating()
        #expect(translations.isShowingTranslation(rowID: single.rowID))
        #expect(!translations.isShowingTranslation(rowID: other.rowID))
    }

    @Test func anEditedMessageTranslatesAgain() async throws {
        let (backend, store, translations, _) = try await makeStore()
        let message = live(backend, store, seq: 4, sender: "lc", text: "es: hola", eventSeq: 100)
        translations.translateMessage(message)
        try await waitUntil { translations.isShowingTranslation(rowID: message.rowID) }

        let edited = live(backend, store, seq: 4, sender: "lc", text: "es: hola, amigos", eventSeq: 101)
        try await waitUntil { translations.presentation(for: edited)?.text == "[en] es: hola, amigos" }
    }

    @Test func aDeclinedDownloadIsReportedAndRetriesOnTap() async throws {
        let (backend, store, translations, translator) = try await makeStore()
        let message = live(backend, store, seq: 4, sender: "lc", text: "es: hola", eventSeq: 100)
        translator.failure = .notDownloaded
        translations.translateMessage(message)
        try await waitUntil { translations.presentation(for: message)?.caption == .notDownloaded }

        translator.failure = nil
        translations.toggleOriginal(rowID: message.rowID)
        try await waitUntil { translations.presentation(for: message)?.caption == .showOriginal }
    }

    @Test func automaticTranslationWaitsForTheLanguageDownload() async throws {
        let (backend, store, translations, translator) = try await makeStore()
        translator.failure = .notDownloaded
        translator.availabilityResult = .downloadable
        let message = live(backend, store, seq: 4, sender: "lc", text: "es: hola", eventSeq: 100)
        translations.translateConversation(from: message)
        try await waitUntil { translations.indicator == .waitingForDownload(source: spanish) }
        #expect(translations.presentation(for: message) == nil)

        translator.failure = nil
        translator.availabilityResult = .installed
        translations.retryAutomaticTranslation()
        try await waitUntil { translations.isShowingTranslation(rowID: message.rowID) }
        #expect(translations.indicator == .translating(source: spanish))
    }

    @Test func unsupportedLanguageIsReportedPerMessage() async throws {
        let (backend, store, translations, translator) = try await makeStore()
        let message = live(backend, store, seq: 4, sender: "lc", text: "xx: ???", eventSeq: 100)
        translator.failure = .unsupported
        translations.translateMessage(message)
        try await waitUntil { translations.presentation(for: message)?.caption == .unsupported(language: "xx") }
    }

    @Test func automaticTranslationPersistsPerConversation() async throws {
        let suite = "cmux.translation.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (backend, store, _, _) = try await makeStore()
        let first = ConversationTranslations(store: store, targetLanguage: english, defaults: defaults, detect: Self.detect)
        let message = live(backend, store, seq: 4, sender: "lc", text: "es: hola", eventSeq: 100)
        first.translator = StubTranslator()
        first.translateConversation(from: message)

        let second = ConversationTranslations(store: store, targetLanguage: english, defaults: defaults, detect: Self.detect)
        second.translator = StubTranslator()
        try await waitUntil { second.isShowingTranslation(rowID: message.rowID) }
        #expect(second.autoTranslation == ConversationAutoTranslation(source: spanish, target: english))
    }
}

@MainActor
final class StubTranslator: ConversationTranslating {
    var failure: ConversationTranslationFailure?
    var availabilityResult: ConversationTranslationAvailability = .installed
    private(set) var calls: [(source: String, target: String, count: Int)] = []

    func availability(from source: Locale.Language, to target: Locale.Language) async -> ConversationTranslationAvailability {
        availabilityResult
    }

    func supportedLanguages() async -> [Locale.Language] {
        ["en", "es", "ja", "fr"].map(Locale.Language.init(identifier:))
    }

    func translate(_ texts: [String: String], from source: Locale.Language, to target: Locale.Language) async throws -> [String: String] {
        calls.append((source.minimalIdentifier, target.minimalIdentifier, texts.count))
        if let failure { throw failure }
        return texts.mapValues { "[\(target.minimalIdentifier)] \($0)" }
    }
}
