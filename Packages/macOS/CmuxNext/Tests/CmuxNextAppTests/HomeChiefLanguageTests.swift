import AppKit
@testable import CmuxHomeCore
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextHomeModel
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// `app.language` reaches the Home Chief chat (Leo 2026-11-16: "we gotta add settings for changing
/// lanugages"). The capture at 9234417 showed the composer's "Message" and the teleport chip's "This
/// Mac" still English in ja and de while the rest of the app had switched: the composer is MessagesLab's
/// (a separate package with its own strings bundle and placeholders localized once), and the chip
/// drew its words once. Both switch live now, and back.
///
/// Each test switches a shared bundle's language as the app does (`AppLanguageApplier.apply`: the
/// bundles' language, then `DesignSettings.appLanguage`) and puts System back before it ends.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefLanguageTests {
    /// Gives the main actor to the views' followers until `done`, for at most 2 s.
    private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    private static func apply(_ code: String?, _ language: AppLanguage) {
        language.set(code)
        DesignSettings.shared.appLanguage = code
    }

    @Test(.timeLimit(.minutes(1)))
    func theComposerPlaceholderFollowsTheAppLanguage() async throws {
        let before = DesignSettings.shared.appLanguage
        let language = AppLanguage()
        language.adopt(MessagesLabHomeView.packageStrings)
        defer {
            Self.apply(nil, language)
            DesignSettings.shared.appLanguage = before
        }
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_language"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        try await Self.until { view.transcript.composerPlaceholder != nil }
        let english = view.transcript.composerPlaceholder
        #expect(english == "Message", "fixture: the English placeholder first")

        Self.apply("ja", language)
        try await Self.until { view.transcript.composerPlaceholder == "メッセージ" }
        #expect(view.transcript.composerPlaceholder == "メッセージ")

        Self.apply("de", language)
        try await Self.until { view.transcript.composerPlaceholder == "Nachricht" }
        #expect(view.transcript.composerPlaceholder == "Nachricht")

        Self.apply(nil, language)
        try await Self.until { view.transcript.composerPlaceholder == english }
        #expect(view.transcript.composerPlaceholder == english)
    }

    @Test(.timeLimit(.minutes(1)))
    func theTeleportChipFollowsTheAppLanguage() async throws {
        let before = DesignSettings.shared.appLanguage
        let language = AppLanguage()
        language.adopt(ChiefTeleportStrings.moduleBundle)
        defer {
            Self.apply(nil, language)
            DesignSettings.shared.appLanguage = before
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chief-chip-language-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ChiefTeleportModel(home: dir, reader: ChiefLocationReader(isRunning: { _ in false }))
        await model.refresh().value
        #expect(model.location == .thisMac, "fixture: the Chief on this Mac")
        let chip = ChiefTeleportChip(model: model)
        let english = chip.accessibilityLabel()
        #expect(english == "Chief location: This Mac", "fixture: the English words first")

        Self.apply("ja", language)
        try await Self.until { chip.accessibilityLabel() == "Chief の場所: このMac" }
        #expect(chip.accessibilityLabel() == "Chief の場所: このMac")

        Self.apply("de", language)
        try await Self.until { chip.accessibilityLabel() == "Ort von Chief: Dieser Mac" }
        #expect(chip.accessibilityLabel() == "Ort von Chief: Dieser Mac")

        Self.apply(nil, language)
        try await Self.until { chip.accessibilityLabel() == english }
        #expect(chip.accessibilityLabel() == english)
    }
}
