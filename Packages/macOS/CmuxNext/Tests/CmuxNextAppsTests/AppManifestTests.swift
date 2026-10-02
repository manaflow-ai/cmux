import Foundation
import Testing
@testable import CmuxNextApps

/// The UI's manifest reading: version 2 `implements`, version 1
/// `contributes`, and leniency (the supervisor validates; the client never
/// refuses a manifest it can show).
struct AppManifestTests {
    @Test func bundledSamplesDecodeWithTheirSections() throws {
        let samples = AppPlatformResources.sampleManifests().map(\.manifest)
        #expect(Set(samples.map(\.id)) == ["cmux/github-prs", "cmux/running-agents", "cmux/agent-status"])
        let prs = try #require(samples.first { $0.id == "cmux/github-prs" })
        let section = try #require(prs.sections.first)
        // v1 samples name the section `prs`; v2 samples key it by interface.
        #expect(["prs", AppImplementation.section].contains(section.id))
        #expect(prs.globalID(of: section) == "cmux/github-prs#\(section.id)")
        #expect(section.title?.english == "Pull Requests")
        #expect(section.symbol == "arrow.triangle.pull")
        #expect(prs.scopes.map(\.scope).contains("net:api.github.com"))
        #expect(prs.optionalScopes.map(\.scope) == ["integration:github:read"])
        #expect(prs.icon == .file("assets/icon.svg"))
        #expect(prs.publisherName == "cmux")
        let status = try #require(samples.first { $0.id == "cmux/agent-status" })
        #expect(status.implementations.contains { $0.isStatusItem })
    }

    @Test func version2ImplementsMapToImplementations() throws {
        let manifest = try #require(AppManifest(json: AppJSON.parse(#"""
        {"manifestVersion":2,"id":"cmux/tasks","name":"Tasks","version":"1.0.0","description":"d","engines":{"cmux":"^2.0"},
         "categories":["productivity"],"scopes":{"tab:read":"Show your tabs."},
         "implements":{"cmux.section/1":{"export":"renderSection","title":"Tasks"},"cmux.search.provider/1":{"export":"search"}},
         "server":{"kind":"native"},"future":{"a":1}}
        """#)))
        #expect(manifest.manifestVersion == 2)
        #expect(manifest.implementations.map(\.interface) == ["cmux.search.provider/1", "cmux.section/1"])
        #expect(manifest.sections.first?.id == "cmux.section/1")
        #expect(manifest.sections.first?.title?.english == "Tasks")
        #expect(manifest.scopes == [AppScopeRequest(scope: "tab:read", reason: "Show your tabs.")])
        #expect(manifest.raw["future"] == ["a": 1])
    }

    @Test func anObjectWithoutAnIDIsNotAManifest() {
        #expect(AppManifest(json: ["name": "x"]) == nil)
        #expect(AppManifest.decode(Data("{".utf8)) == nil)
        #expect(AppManifest(json: ["id": "local/x"])?.name.english == "local/x")
    }

    @Test func localizedTextFallsBackFromRegionToBaseToEnglish() {
        let text = AppLocalizedText(values: ["en": "Agents", "ja": "エージェント", "pt": "Agentes"])
        #expect(text.resolved(preferredLanguages: ["ja-JP"]) == "エージェント")
        #expect(text.resolved(preferredLanguages: ["pt-BR"]) == "Agentes")
        #expect(text.resolved(preferredLanguages: ["de"]) == "Agents")
    }

    @Test func recordsRoundTripTheirWireShape() throws {
        let record = try #require(FakeAppsTransport.sampleRecords().first { $0.id == "cmux/agent-status" })
        #expect(record.isDefault && record.installed)
        #expect(AppRecord(json: record.json) == record)
        #expect(AppRecord(json: ["id": "cmux/x"]) == nil)
    }
}
