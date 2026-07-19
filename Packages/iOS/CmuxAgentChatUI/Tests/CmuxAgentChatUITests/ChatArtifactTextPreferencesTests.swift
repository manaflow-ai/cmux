import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text preferences", .serialized)
struct ChatArtifactTextPreferencesTests {
    @Test("log defaults differ and explicit wrap choices persist per kind")
    func wrapPersistence() throws {
        let suiteName = "ChatArtifactTextPreferencesTests.wrap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ChatArtifactTextPreferences(defaults: defaults, keyPrefix: "test")

        #expect(!preferences.wrapsLines(for: .log))
        #expect(preferences.wrapsLines(for: .code))
        #expect(preferences.wrapsLines(for: .plainText))

        preferences.setWrapsLines(true, for: .log)
        preferences.setWrapsLines(false, for: .code)
        let reloaded = ChatArtifactTextPreferences(defaults: defaults, keyPrefix: "test")
        #expect(reloaded.wrapsLines(for: .log))
        #expect(!reloaded.wrapsLines(for: .code))
        #expect(reloaded.wrapsLines(for: .plainText))
    }

    @Test("font sizes persist independently and clamp to the supported range")
    func fontPersistence() throws {
        let suiteName = "ChatArtifactTextPreferencesTests.font.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ChatArtifactTextPreferences(defaults: defaults, keyPrefix: "test")

        #expect(preferences.fontSize(for: .code) == ChatArtifactTextPreferences.defaultFontSize)
        #expect(preferences.setFontSize(40, for: .code) == 28)
        #expect(preferences.setFontSize(6, for: .log) == 8)

        let reloaded = ChatArtifactTextPreferences(defaults: defaults, keyPrefix: "test")
        #expect(reloaded.fontSize(for: .code) == 28)
        #expect(reloaded.fontSize(for: .log) == 8)
        #expect(reloaded.fontSize(for: .plainText) == ChatArtifactTextPreferences.defaultFontSize)
    }

    @Test("paths resolve to stable preference kinds")
    func kindResolution() {
        #expect(ChatArtifactTextLayoutKind(path: "/tmp/build.log") == .log)
        #expect(ChatArtifactTextLayoutKind(path: "/tmp/process.OUT") == .log)
        #expect(ChatArtifactTextLayoutKind(path: "/tmp/main.swift") == .code)
        #expect(ChatArtifactTextLayoutKind(path: "/tmp/README") == .plainText)
    }
}
