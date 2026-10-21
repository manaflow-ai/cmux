#if canImport(Translation) && canImport(SwiftUI)
import CmuxConversationCore
import Foundation
import SwiftUI
import Translation

/// On-device translation through Apple's Translation framework.
///
/// A `TranslationSession` only exists inside SwiftUI's `translationTask`,
/// which is also what presents the system "download language" prompt. The
/// engine therefore owns a zero-size SwiftUI host that the conversation view
/// keeps in its window; requests queue here and drain through that session.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
public final class ConversationTranslationEngine: ConversationTranslating {
    let driver = TranslationDriver()

    public init() {}

    /// Embed this (any size, it draws nothing) in the conversation's view
    /// hierarchy. Translations wait while it is out of a window.
    public var hostView: some View { TranslationHostView(driver: driver) }

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> ConversationTranslationAvailability {
        await Self.status(from: source, to: target)
    }

    public func supportedLanguages() async -> [Locale.Language] {
        await Self.supported()
    }

    // LanguageAvailability is not Sendable: create and use it off the main actor.
    private nonisolated static func status(from source: Locale.Language, to target: Locale.Language) async -> ConversationTranslationAvailability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    private nonisolated static func supported() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    public func translate(_ texts: [String: String], from source: Locale.Language, to target: Locale.Language) async throws -> [String: String] {
        guard !texts.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            driver.enqueue(TranslationDriver.Job(texts: texts, source: source, target: target, continuation: continuation))
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
@MainActor
final class TranslationDriver: ObservableObject {
    struct Job: Sendable {
        var texts: [String: String]
        var source: Locale.Language
        var target: Locale.Language
        var continuation: CheckedContinuation<[String: String], any Error>
    }

    @Published var configuration: TranslationSession.Configuration?
    private var jobs: [Job] = []
    private var isRunning = false

    func enqueue(_ job: Job) {
        jobs.append(job)
        startIfIdle()
    }

    /// Points the session at the next job's language pair. A changed pair
    /// starts a new session; the same pair is re-run by invalidating it.
    private func startIfIdle() {
        guard !isRunning, let next = jobs.first else { return }
        if var current = configuration, current.source == next.source, current.target == next.target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: next.source, target: next.target)
        }
    }

    /// Hands the next job for a session's language pair to the session.
    func takeJob(source: Locale.Language?, target: Locale.Language?) -> Job? {
        isRunning = true
        guard let index = jobs.firstIndex(where: { $0.source == source && $0.target == target }) else { return nil }
        return jobs.remove(at: index)
    }

    func sessionFinished() {
        isRunning = false
        startIfIdle()
    }

    /// The `translationTask` body: drains every job for this session's pair.
    /// Runs off the main actor, where the (non-Sendable) session lives.
    nonisolated static func drain(_ session: TranslationSession, driver: TranslationDriver) async {
        let source = session.sourceLanguage
        let target = session.targetLanguage
        while let job = await driver.takeJob(source: source, target: target) {
            let requests = job.texts.map { TranslationSession.Request(sourceText: $0.value, clientIdentifier: $0.key) }
            do {
                let responses = try await session.translations(from: requests)
                var result: [String: String] = [:]
                for response in responses {
                    if let id = response.clientIdentifier { result[id] = response.targetText }
                }
                job.continuation.resume(returning: result)
            } catch {
                job.continuation.resume(throwing: failure(for: error))
            }
        }
        await driver.sessionFinished()
    }

    nonisolated static func failure(for error: any Error) -> ConversationTranslationFailure {
        if error is CancellationError { return .notDownloaded }
        if TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error
            || TranslationError.unsupportedLanguagePairing ~= error {
            return .unsupported
        }
        if TranslationError.unableToIdentifyLanguage ~= error { return .unidentifiedLanguage }
        if #available(iOS 26.0, macOS 26.0, *) {
            if TranslationError.notInstalled ~= error || TranslationError.alreadyCancelled ~= error { return .notDownloaded }
        }
        return .failed
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct TranslationHostView: View {
    @ObservedObject var driver: TranslationDriver

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .translationTask(driver.configuration) { @Sendable [driver] session in
                await TranslationDriver.drain(session, driver: driver)
            }
    }
}
#endif
