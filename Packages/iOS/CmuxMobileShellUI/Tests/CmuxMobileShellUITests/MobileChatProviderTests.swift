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
        let providers = model.sessions.compactMap { MobileChatProvider.resolve($0.agentKind) }
        #expect(providers.contains(.codex))
        #expect(providers.contains(.claude))
        #expect(providers.contains(.openCode))
        #expect(model.messages(for: "preview-codex").count == 3)
    }

    @Test("does not relabel unknown agents as OpenCode")
    func unknownProviderIsUnsupported() {
        #expect(MobileChatProvider.resolve(.other("pi")) == nil)
        #expect(MobileChatProvider.resolve(.other("opencode")) == .openCode)
    }
}
