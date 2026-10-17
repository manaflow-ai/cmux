import Testing
@testable import CmuxMobileShellUI

@Suite("Native Chat")
struct MobileChatProviderTests {
    @Test("offers exactly the supported native chat agents")
    func providerCatalog() {
        #expect(MobileChatProvider.allCases.map(\.rawValue) == ["codex", "claude", "opencode"])
        #expect(MobileChatProvider.allCases.map(\.title) == ["Codex", "Claude", "OpenCode"])
    }

    @Test("preview model includes one recent session for each provider")
    @MainActor
    func previewSessions() {
        let model = MobileChatHomeModel()
        model.loadPreview()

        #expect(model.sessions.count == 3)
        #expect(model.sessions.map { MobileChatProvider.resolve($0.agentKind) }.contains(.codex))
        #expect(model.sessions.map { MobileChatProvider.resolve($0.agentKind) }.contains(.claude))
        #expect(model.sessions.map { MobileChatProvider.resolve($0.agentKind) }.contains(.openCode))
        #expect(model.messages(for: "preview-codex").count == 3)
    }
}
