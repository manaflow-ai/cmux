import Foundation
import Testing
@testable import CmuxNextApps

/// The manifest model against the fixtures shared with the TypeScript
/// validator (`cmux-tui/crates/cmux-app-host/schema/fixtures`).
struct AppManifestTests {
    private func files(_ kind: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: AppPlatformResources.fixtures.appending(path: kind), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".expect.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func everyValidFixtureDecodes() throws {
        let valid = try files("valid")
        #expect(valid.count >= 2)
        for url in valid {
            #expect(throws: Never.self, "\(url.lastPathComponent)") { _ = try AppManifest.decode(Data(contentsOf: url)) }
        }
    }

    @Test func everyInvalidFixtureReportsItsExpectedPathAndCode() throws {
        let invalid = try files("invalid")
        #expect(invalid.count >= 8)
        for url in invalid {
            let expectURL = url.deletingPathExtension().appendingPathExtension("expect.json")
            let expected = try AppJSON.parse(Data(contentsOf: expectURL))
            let path = try #require(expected["path"]?.stringValue)
            let code = try #require(expected["code"]?.stringValue)
            let data = try Data(contentsOf: url)
            do {
                _ = try AppManifest.decode(data)
                Issue.record("\(url.lastPathComponent) decoded but should fail at \(path)")
            } catch {
                #expect(error.issues.contains { $0.path == path && $0.code == code },
                        "\(url.lastPathComponent): expected \(path) \(code), got \(error.issues)")
            }
        }
    }

    @Test func bundledSamplesDecodeWithTheirContributions() throws {
        let manifests = try ["github-prs", "running-agents", "agent-status"].map { name in
            try AppManifest.decode(Data(contentsOf: AppPlatformResources.samples.appending(path: "\(name)/cmux-app.json")))
        }
        #expect(manifests.map(\.id) == ["cmux/github-prs", "cmux/running-agents", "cmux/agent-status"])
        let prs = manifests[0]
        let section = try #require(prs.contributes.of(.sidebarSection).first)
        #expect(prs.globalID(of: section) == "cmux/github-prs#prs")
        #expect(section.export == "renderPRs")
        #expect(section.maxRows == 10)
        #expect(prs.scopes.map(\.scope).contains("net:api.github.com"))
        #expect(prs.contributes.settingsDefaults["showDrafts"] == .bool(true))
        #expect(manifests[2].contributes.of(.statusItem).first?.export == "renderStatus")
        #expect(prs.icon == .file("assets/icon.svg"))
    }

    @Test func codableDecodeNamesThePathOfTheFirstIssue() throws {
        let bad = #"{"manifestVersion":1,"id":"Bad Id","name":"x","version":"1.0.0","description":"d","engines":{"cmux":"^1.0"}}"#
        do {
            _ = try JSONDecoder().decode(AppManifest.self, from: Data(bad.utf8))
            Issue.record("decoded an invalid id")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.hasPrefix("/id:"))
        }
    }

    @Test func unknownTopLevelKeysFailButUnknownContributionKeysSurvive() throws {
        let manifest = try AppManifest.decode(AppJSON.parse(#"""
        {"manifestVersion":1,"id":"local/x","name":"X","version":"0.1.0","description":"d","engines":{"cmux":"^1.0"},
         "contributes":{"sidebarSections":[{"id":"s","title":"S","render":"r","future":{"a":1}}]}}
        """#))
        #expect(manifest.contributes.entries.first?.raw["future"] == ["a": 1])
        #expect(manifest.isLocal)
        #expect(throws: AppManifestError.self) {
            try AppManifest.decode(AppJSON.parse(#"{"manifestVersion":1,"id":"local/x","name":"X","version":"0.1.0","description":"d","engines":{"cmux":"^1.0"},"extra":1}"#))
        }
    }

    @Test func malformedJSONIsUnreadable() {
        #expect(throws: AppManifestError.self) { try AppManifest.decode(Data("{".utf8)) }
    }

    @Test func localizedTextFallsBackFromRegionToBaseToEnglish() {
        let text = AppLocalizedText(values: ["en": "Agents", "ja": "エージェント", "pt": "Agentes"])
        #expect(text.resolved(preferredLanguages: ["ja-JP"]) == "エージェント")
        #expect(text.resolved(preferredLanguages: ["pt-BR"]) == "Agentes")
        #expect(text.resolved(preferredLanguages: ["de"]) == "Agents")
    }
}
