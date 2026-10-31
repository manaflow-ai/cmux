import Foundation
import Testing
@testable import CmuxFoundation

struct CmuxFoundationLocalizationTests {
    @Test func missingResourcesUseTheDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(CmuxFoundationLocalization.findBundle(in: [directory]) == nil)
        #expect(CmuxFoundationLocalization.string(
            "glaeda.cli.taskHelp", defaultValue: "glaeda <request|observe> [options]", bundle: nil
        ) == "glaeda <request|observe> [options]")
    }

    @Test func availableResourcesStillTranslate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = directory.appendingPathComponent("CmuxFoundation_CmuxFoundation.bundle")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try Data("\"fixture.key\" = \"Translated fixture\";".utf8)
            .write(to: resource.appendingPathComponent("Localizable.strings"))
        let bundle = try #require(CmuxFoundationLocalization.findBundle(in: [directory]))
        #expect(CmuxFoundationLocalization.string(
            "fixture.key", defaultValue: "Fallback fixture", bundle: bundle
        ) == "Translated fixture")
        #expect(CmuxFoundationLocalization.string(
            "fixture.missing", defaultValue: "Missing key fallback", bundle: bundle
        ) == "Missing key fallback")
    }

    @Test func packageTestsFindTheirProcessedBundle() throws {
        let bundle = try #require(CmuxFoundationLocalization.bundle)
        #expect(bundle.bundleURL.lastPathComponent == "CmuxFoundation_CmuxFoundation.bundle")
    }
}
