import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Whether on-device translation between two languages can run now.
public enum ConversationTranslationAvailability: Sendable, Hashable {
    /// Both language models are on the device.
    case installed
    /// Supported, but a model download (system prompt) comes first.
    case downloadable
    case unsupported
}

public enum ConversationTranslationFailure: Error, Sendable, Hashable {
    /// The pair is not supported on this device.
    case unsupported
    /// The model is not on the device and was not downloaded (prompt declined).
    case notDownloaded
    case unidentifiedLanguage
    case failed
}

/// The line under a message that has translation state.
public enum ConversationTranslationCaption: Sendable, Hashable {
    case translating
    /// The translation is shown; tapping shows the original.
    case showOriginal
    /// The original is shown; tapping shows the translation again.
    case viewTranslation
    case notDownloaded
    /// `language` is a BCP 47 identifier of the source, when known.
    case unsupported(language: String?)
}

/// Conversation-level translation status shown above the composer.
public enum ConversationTranslationIndicator: Sendable, Hashable {
    case translating(source: Locale.Language)
    /// Automatic translation is on but the language model is not downloaded.
    case waitingForDownload(source: Locale.Language)
    /// This device cannot translate the source language.
    case unsupported(source: Locale.Language)
}

public struct ConversationAutoTranslation: Sendable, Hashable {
    public var source: Locale.Language
    public var target: Locale.Language

    public init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
    }
}

/// What starting a translation needs from the person.
public enum ConversationTranslateOutcome: Sendable, Equatable {
    case started
    /// The source language could not be detected, or matches the target:
    /// ask "Translate From" before translating.
    case needsSourceLanguage
    case unavailable
}

/// The on-device translator (Apple's Translation framework in the apps, a
/// stub in tests). Lives above Core so Core stays framework-free.
@MainActor
public protocol ConversationTranslating: AnyObject {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> ConversationTranslationAvailability
    func supportedLanguages() async -> [Locale.Language]
    /// Translates `texts` (keyed by caller id). May present the system
    /// download prompt. Throws `ConversationTranslationFailure`.
    func translate(_ texts: [String: String], from source: Locale.Language, to target: Locale.Language) async throws -> [String: String]
}

extension Locale.Language {
    /// Same language for translation purposes (es-MX matches es; zh-Hant does not match zh-Hans).
    func translationMatches(_ other: Locale.Language) -> Bool {
        guard let code = languageCode, let otherCode = other.languageCode, code == otherCode else { return false }
        if let script, let otherScript = other.script { return script == otherScript }
        return true
    }
}

/// Client-side translation state for one conversation: per-message
/// translations (keyed by row id, so a pending send keeps its state when the
/// server acknowledges it) and the conversation's automatic translation.
/// Nothing here goes over the wire; the backend only ever sees originals.
@MainActor
public final class ConversationTranslations {
    private enum Phase: Equatable {
        case translating
        case translated(String)
        case failed(ConversationTranslationFailure)
    }

    private struct Entry: Equatable {
        /// The original the phase belongs to; an edit makes the entry stale.
        var sourceText: String
        var source: Locale.Language
        var phase: Phase
        var showsOriginal = false
        /// Created by automatic translation (removed when it stops).
        var isAutomatic: Bool
    }

    /// Set by the hosting UI when on-device translation exists (iOS 18 / macOS 15).
    public var translator: (any ConversationTranslating)? {
        didSet {
            refreshAutoAvailability()
            if autoTranslation != nil { scheduleAutomatic() }
            changed()
        }
    }
    public let targetLanguage: Locale.Language
    public private(set) var autoTranslation: ConversationAutoTranslation?
    public private(set) var autoAvailability: ConversationTranslationAvailability?

    private weak var store: ConversationStore?
    private let detect: (String) -> Locale.Language?
    private let defaults: UserDefaults?
    private var entries: [String: Entry] = [:]
    private var detected: [String: (text: String, language: Locale.Language?)] = [:]
    private var loadedConversationID: String?
    private var work: Task<Void, Never>?
    /// Automatic translation hit a missing model; it resumes once the model
    /// is installed (or the person asks to download it), instead of
    /// re-prompting on every arrival.
    private var autoWaitsForDownload = false
    private var isNotifying = false

    public init(
        store: ConversationStore,
        targetLanguage: Locale.Language = ConversationTranslations.deviceLanguage,
        defaults: UserDefaults? = .standard,
        detect: @escaping (String) -> Locale.Language? = ConversationTranslations.detectLanguage
    ) {
        self.store = store
        self.targetLanguage = targetLanguage
        self.defaults = defaults
        self.detect = detect
        store.addObserver { [weak self] change in self?.storeChanged(change) }
        // Created lazily, possibly while a row builder reads it: restoring a
        // saved automatic translation must not notify from inside that build.
        Task { [weak self] in self?.restoreAutoTranslation() }
    }

    /// The person's preferred language, reduced to what translation keys on.
    public static var deviceLanguage: Locale.Language {
        let preferred = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) } ?? Locale.current.language
        guard let code = preferred.languageCode else { return Locale.Language(identifier: "en") }
        if let script = preferred.script, code.identifier == "zh" {
            return Locale.Language(languageCode: code, script: script)
        }
        return Locale.Language(languageCode: code)
    }

    /// Dominant language of `text`, or nil when the recognizer is unsure
    /// (short replies like "lol" or "ok" carry no reliable signal).
    public nonisolated static func detectLanguage(_ text: String) -> Locale.Language? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= 0.5 else { return nil }
        return Locale.Language(identifier: language.rawValue)
        #else
        return nil
        #endif
    }

    // MARK: Queries

    public var isAvailable: Bool { translator != nil }

    public func canTranslate(_ message: ConversationMessage) -> Bool {
        translator != nil && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func detectedLanguage(of message: ConversationMessage) -> Locale.Language? {
        if let cached = detected[message.rowID], cached.text == message.text { return cached.language }
        let language = detect(message.text)
        detected[message.rowID] = (message.text, language)
        return language
    }

    /// Whether the transcript shows a translation (not the original) for the row.
    public func isShowingTranslation(rowID: String) -> Bool {
        guard let entry = entries[rowID], case .translated = entry.phase else { return false }
        return !entry.showsOriginal
    }

    public func hasTranslation(rowID: String) -> Bool {
        guard let entry = entries[rowID], case .translated = entry.phase else { return false }
        return true
    }

    /// The text to draw for `message` and the caption under it, or nil when
    /// the message has no translation state.
    public func presentation(for message: ConversationMessage) -> (text: String, caption: ConversationTranslationCaption)? {
        guard let entry = entries[message.rowID], entry.sourceText == message.text else { return nil }
        switch entry.phase {
        case .translating:
            return (message.text, .translating)
        case let .translated(text):
            return entry.showsOriginal ? (message.text, .viewTranslation) : (text, .showOriginal)
        case .failed(.notDownloaded):
            return (message.text, .notDownloaded)
        case .failed:
            return (message.text, .unsupported(language: entry.source.minimalIdentifier))
        }
    }

    public var indicator: ConversationTranslationIndicator? {
        guard let auto = autoTranslation else { return nil }
        if autoAvailability == .unsupported { return .unsupported(source: auto.source) }
        if autoAvailability == .downloadable, !hasAutomaticTranslation {
            return .waitingForDownload(source: auto.source)
        }
        return .translating(source: auto.source)
    }

    private var hasAutomaticTranslation: Bool {
        entries.values.contains { entry in
            guard entry.isAutomatic, case .translated = entry.phase else { return false }
            return true
        }
    }

    // MARK: Actions

    /// "Translate This Message". `source` overrides detection (from the
    /// "Translate From" picker).
    @discardableResult
    public func translateMessage(_ message: ConversationMessage, from source: Locale.Language? = nil) -> ConversationTranslateOutcome {
        guard canTranslate(message) else { return .unavailable }
        guard let source = source ?? detectedLanguage(of: message), !source.translationMatches(targetLanguage) else {
            return .needsSourceLanguage
        }
        if let entry = entries[message.rowID], entry.sourceText == message.text, case .translated = entry.phase {
            entries[message.rowID]?.showsOriginal = false
            changed()
            return .started
        }
        entries[message.rowID] = Entry(sourceText: message.text, source: source, phase: .translating, isAutomatic: false)
        changed()
        run([message.rowID])
        return .started
    }

    /// "Translate Conversation": translates the loaded messages others sent in
    /// `message`'s language and every later one, until stopped.
    @discardableResult
    public func translateConversation(from message: ConversationMessage, source: Locale.Language? = nil) -> ConversationTranslateOutcome {
        guard translator != nil else { return .unavailable }
        guard let source = source ?? detectedLanguage(of: message), !source.translationMatches(targetLanguage) else {
            return .needsSourceLanguage
        }
        startAutomaticTranslation(source: source)
        // The pressed message translates even if it is mine or ambiguous.
        if canTranslate(message), !isShowingTranslation(rowID: message.rowID) {
            entries[message.rowID] = Entry(sourceText: message.text, source: source, phase: .translating, isAutomatic: true)
            changed()
            run([message.rowID])
        }
        return .started
    }

    public func startAutomaticTranslation(source: Locale.Language) {
        autoTranslation = ConversationAutoTranslation(source: source, target: targetLanguage)
        autoAvailability = nil
        autoWaitsForDownload = false
        persistAutoTranslation()
        refreshAutoAvailability()
        scheduleAutomatic()
        changed()
    }

    /// "Stop Translation": originals return for automatic translations;
    /// messages translated one by one keep theirs.
    public func stopTranslating() {
        autoTranslation = nil
        autoAvailability = nil
        autoWaitsForDownload = false
        entries = entries.filter { !$0.value.isAutomatic }
        persistAutoTranslation()
        changed()
    }

    /// The caption's "Show Original" / "View Translation".
    public func toggleOriginal(rowID: String) {
        guard let entry = entries[rowID] else { return }
        switch entry.phase {
        case .translated:
            entries[rowID]?.showsOriginal.toggle()
        case .failed:
            // A failed translation retries (the download prompt reappears).
            entries[rowID]?.phase = .translating
            run([rowID])
        case .translating:
            return
        }
        changed()
    }

    /// Asks for the model again after a declined download.
    public func retryAutomaticTranslation() {
        guard autoTranslation != nil else { return }
        autoAvailability = nil
        autoWaitsForDownload = false
        for (rowID, entry) in entries where entry.isAutomatic {
            if case .failed = entry.phase { entries[rowID] = nil }
        }
        scheduleAutomatic()
        changed()
    }

    // MARK: Store changes

    private func storeChanged(_ change: ConversationStoreChange) {
        guard !isNotifying else { return }
        switch change {
        case .typing, .older, .readState, .listState:
            return
        case .connection:
            restoreAutoTranslation()
            return
        case .reset, .prepended, .live:
            break
        }
        guard let store else { return }
        // Edits invalidate translations; the new text translates again.
        var stale: [String] = []
        for message in store.messages {
            guard let entry = entries[message.rowID], entry.sourceText != message.text else { continue }
            entries[message.rowID]?.sourceText = message.text
            entries[message.rowID]?.phase = .translating
            entries[message.rowID]?.showsOriginal = false
            stale.append(message.rowID)
        }
        if !stale.isEmpty {
            changed()
            run(stale)
        }
        if autoWaitsForDownload {
            refreshAutoAvailability()
        } else if autoTranslation != nil {
            scheduleAutomatic()
        }
    }

    /// Queues every loaded message others sent in the automatic source language.
    private func scheduleAutomatic() {
        guard let auto = autoTranslation, translator != nil, let store else { return }
        guard autoAvailability != .unsupported, !autoWaitsForDownload else { return }
        var queued: [String] = []
        for message in store.messages where message.senderID != store.meID && entries[message.rowID] == nil {
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let language = detectedLanguage(of: message), language.translationMatches(auto.source) else { continue }
            entries[message.rowID] = Entry(sourceText: message.text, source: auto.source, phase: .translating, isAutomatic: true)
            queued.append(message.rowID)
        }
        guard !queued.isEmpty else { return }
        changed()
        run(queued)
    }

    // MARK: Running

    /// Translates rows one batch per source language, after earlier batches
    /// (one session at a time, so the download prompt appears once).
    private func run(_ rowIDs: [String]) {
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.translate(rowIDs)
        }
    }

    private func translate(_ rowIDs: [String]) async {
        guard let translator else { return }
        var bySource: [Locale.Language: [String: String]] = [:]
        for rowID in rowIDs {
            guard let entry = entries[rowID], entry.phase == .translating else { continue }
            bySource[entry.source, default: [:]][rowID] = entry.sourceText
        }
        for (source, texts) in bySource {
            let result: Result<[String: String], ConversationTranslationFailure>
            do {
                result = .success(try await translator.translate(texts, from: source, to: targetLanguage))
            } catch let failure as ConversationTranslationFailure {
                result = .failure(failure)
            } catch {
                result = .failure(.failed)
            }
            for (rowID, sourceText) in texts {
                // Skip rows edited, stopped or retried while this batch ran.
                guard let entry = entries[rowID], entry.sourceText == sourceText, entry.phase == .translating else { continue }
                switch result {
                case let .success(translations):
                    if let text = translations[rowID], !text.isEmpty {
                        entries[rowID]?.phase = .translated(text)
                        if entry.isAutomatic { autoAvailability = .installed }
                    } else {
                        entries[rowID]?.phase = .failed(.failed)
                    }
                case let .failure(failure):
                    if entry.isAutomatic {
                        // Automatic translation shows originals until the
                        // language is downloaded; the indicator says so.
                        entries[rowID] = nil
                        if failure == .notDownloaded {
                            autoAvailability = .downloadable
                            autoWaitsForDownload = true
                        }
                        if failure == .unsupported { autoAvailability = .unsupported }
                    } else {
                        entries[rowID]?.phase = .failed(failure)
                    }
                }
            }
            changed()
        }
    }

    private func refreshAutoAvailability() {
        guard let auto = autoTranslation, let translator else { return }
        Task { [weak self] in
            let availability = await translator.availability(from: auto.source, to: auto.target)
            guard let self, self.autoTranslation == auto else { return }
            if self.autoAvailability != availability {
                self.autoAvailability = availability
                self.changed()
            }
            // Downloaded meanwhile (prompt, Settings): translation begins.
            if availability == .installed, self.autoWaitsForDownload {
                self.autoWaitsForDownload = false
                self.scheduleAutomatic()
            }
        }
    }

    // MARK: Persistence

    private func persistenceKey(_ conversationID: String) -> String {
        "cmux.conversation.autoTranslate.\(conversationID)"
    }

    private func persistAutoTranslation() {
        guard let defaults, let id = store?.info?.id else { return }
        if let auto = autoTranslation {
            defaults.set([auto.source.minimalIdentifier, auto.target.minimalIdentifier], forKey: persistenceKey(id))
        } else {
            defaults.removeObject(forKey: persistenceKey(id))
        }
    }

    private func restoreAutoTranslation() {
        guard let id = store?.info?.id, loadedConversationID != id else { return }
        loadedConversationID = id
        guard let defaults, let pair = defaults.stringArray(forKey: persistenceKey(id)), pair.count == 2 else { return }
        let target = Locale.Language(identifier: pair[1])
        // A different device language starts fresh.
        guard target.translationMatches(targetLanguage) else { return }
        autoTranslation = ConversationAutoTranslation(source: Locale.Language(identifier: pair[0]), target: targetLanguage)
        refreshAutoAvailability()
        scheduleAutomatic()
        changed()
    }

    private func changed() {
        guard let store else { return }
        isNotifying = true
        store.translationsDidChange()
        isNotifying = false
    }
}
