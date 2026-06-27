import Foundation
import Testing
@testable import CmuxSettings

@Suite("AutoNamingAgentCatalog")
struct AutoNamingAgentCatalogTests {
    @Test func autoSlugAndSupportedMembership() {
        #expect(AutoNamingAgentCatalog.autoSlug == "auto")
        for slug in ["claude", "codex", "grok", "opencode", "pi", "omp"] {
            #expect(AutoNamingAgentCatalog.summarizerSupported(slug: slug))
        }
        #expect(!AutoNamingAgentCatalog.summarizerSupported(slug: "gemini"))
        #expect(!AutoNamingAgentCatalog.summarizerSupported(slug: "totally-unknown"))
    }

    @Test func partitionsSupportedAndOther() {
        let supported = Set(AutoNamingAgentCatalog.supportedAgents.map(\.slug))
        let other = Set(AutoNamingAgentCatalog.otherAgents.map(\.slug))
        #expect(supported.isDisjoint(with: other))
        #expect(supported.contains("claude"))
        #expect(other.contains("gemini"))
        // Catalog flag and membership helper must agree for every option.
        for option in AutoNamingAgentCatalog.agents {
            #expect(option.summarizerSupported == AutoNamingAgentCatalog.summarizerSupported(slug: option.slug))
        }
    }

    @Test func displayNameFallsBackToSlugForCustomAgents() {
        #expect(AutoNamingAgentCatalog.displayName(forSlug: "claude") == "Claude Code")
        #expect(AutoNamingAgentCatalog.displayName(forSlug: "my-custom-agent") == "my-custom-agent")
    }

    // MARK: resolveSummarizer decision matrix

    @Test func autoEmptyOrSelfResolvesToSessionAgent() {
        let installed: (String) -> Bool = { _ in true }
        #expect(AutoNamingAgentCatalog.resolveSummarizer(chosen: nil, sessionAgent: "claude", isInstalled: installed)
            == .init(agent: "claude", missingOverride: nil))
        #expect(AutoNamingAgentCatalog.resolveSummarizer(chosen: "auto", sessionAgent: "claude", isInstalled: installed)
            == .init(agent: "claude", missingOverride: nil))
        #expect(AutoNamingAgentCatalog.resolveSummarizer(chosen: "   ", sessionAgent: "grok", isInstalled: installed)
            == .init(agent: "grok", missingOverride: nil))
        // Choosing the session's own agent is a no-op override.
        #expect(AutoNamingAgentCatalog.resolveSummarizer(chosen: "codex", sessionAgent: "codex", isInstalled: installed)
            == .init(agent: "codex", missingOverride: nil))
    }

    @Test func supportedOverrideUsesChosenWhenInstalled() {
        let decision = AutoNamingAgentCatalog.resolveSummarizer(
            chosen: "codex", sessionAgent: "claude", isInstalled: { $0 == "codex" })
        #expect(decision == .init(agent: "codex", missingOverride: nil))
    }

    @Test func supportedOverrideFallsBackAndReportsWhenMissing() {
        let decision = AutoNamingAgentCatalog.resolveSummarizer(
            chosen: "codex", sessionAgent: "claude", isInstalled: { _ in false })
        #expect(decision == .init(agent: "claude", missingOverride: "codex"))
    }

    @Test func unsupportedOverrideFallsBackSilently() {
        // gemini is selectable but not driveable yet: fall back, no report.
        let decision = AutoNamingAgentCatalog.resolveSummarizer(
            chosen: "gemini", sessionAgent: "claude", isInstalled: { _ in true })
        #expect(decision == .init(agent: "claude", missingOverride: nil))
    }
}

@Suite("AutoNamingStatusStore")
struct AutoNamingStatusStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
    }

    @Test func recordCurrentClearRoundTrip() {
        let defaults = makeDefaults()
        #expect(AutoNamingStatusStore.current(in: defaults) == nil)
        AutoNamingStatusStore.record(rawCategory: "failed", agent: "codex", at: 123, in: defaults)
        #expect(AutoNamingStatusStore.current(in: defaults)
            == AutoNamingStatus(category: .failed, agent: "codex", at: 123))
        AutoNamingStatusStore.clear(in: defaults)
        #expect(AutoNamingStatusStore.current(in: defaults) == nil)
    }

    @Test func notInstalledCategoryMapsFromRawSocketField() {
        let defaults = makeDefaults()
        AutoNamingStatusStore.record(rawCategory: "not_installed", agent: "omp", at: 1, in: defaults)
        #expect(AutoNamingStatusStore.current(in: defaults)?.category == .notInstalled)
    }

    @Test func diagnosticCategoriesMapFromRawSocketFields() {
        for raw in ["probe_failed", "extraction_failed", "apply_failed"] {
            let defaults = makeDefaults()
            AutoNamingStatusStore.record(rawCategory: raw, agent: "codex", at: 1, in: defaults)
            #expect(AutoNamingStatusStore.current(in: defaults)?.category.rawValue == raw)
        }
    }

    @Test func unknownCategoryIsIgnored() {
        let defaults = makeDefaults()
        AutoNamingStatusStore.record(rawCategory: "bogus", agent: "x", at: 1, in: defaults)
        #expect(AutoNamingStatusStore.current(in: defaults) == nil)
    }
}
