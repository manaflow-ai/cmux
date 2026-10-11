@testable import CmuxNextSettings
import Foundation
import Testing

/// The published MDM schema (docs/mdm) is generated from the settings
/// catalog. A new or changed setting fails this test until the files are
/// regenerated: `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests`.
@Suite struct ManagedPreferencesManifestTests {
    static let docs: URL = {
        // Tests/CmuxNextSettingsTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appending(path: "docs/mdm")
    }()

    static func generated() throws -> [(String, Data)] {
        [
            ("com.manaflow.cmux.plist", try ManagedPreferencesManifest.profileManifest()),
            ("com.manaflow.cmux.json", try ManagedPreferencesManifest.jamfSchema() + Data("\n".utf8)),
            ("cmux-example.mobileconfig", try ManagedPreferencesManifest.exampleMobileconfig()),
            ("com.manaflow.cmux.intune.plist", Data(try ManagedPreferencesManifest.intunePreferenceFile().utf8)),
            ("managed-preferences.md", Data(ManagedPreferencesManifest.markdown().utf8)),
        ]
    }

    @Test func checkedInSchemaMatchesTheCatalog() throws {
        let files = try Self.generated()
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_MDM_SCHEMA"] == "1" {
            try FileManager.default.createDirectory(at: Self.docs, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: Self.docs.appending(path: name)) }
        }
        for (name, data) in files {
            let onDisk = try? Data(contentsOf: Self.docs.appending(path: name))
            #expect(onDisk == data, "docs/mdm/\(name) is stale; regenerate with CMUX_UPDATE_MDM_SCHEMA=1")
        }
    }

    @Test func everyCatalogKeyIsInTheSchemaWithItsType() throws {
        let manifest = try #require(try PropertyListSerialization.propertyList(from: ManagedPreferencesManifest.profileManifest(), format: nil) as? [String: Any])
        #expect(manifest["pfm_domain"] as? String == ManagedPreferences.domain)
        let subkeys = try #require(manifest["pfm_subkeys"] as? [[String: Any]])
        let names = subkeys.compactMap { $0["pfm_name"] as? String }
        // MDM manages what cmux-next applies; keys only cmux-browser reads are not published.
        let published = SettingsSchema.all.filter(\.isShownInCmuxNext)
        #expect(Set(names) == Set(published.map(\.id) + ManagedPreferences.policyKeys.map(\.name)))
        #expect(names.count == Set(names).count)
        for (descriptor, key) in zip(published, subkeys) where descriptor.kind == .toggle {
            #expect(key["pfm_type"] as? String == "boolean")
        }
    }

    @Test func exampleProfileIsAValidConfigurationProfile() throws {
        let profile = try #require(try PropertyListSerialization.propertyList(from: ManagedPreferencesManifest.exampleMobileconfig(), format: nil) as? [String: Any])
        #expect(profile["PayloadType"] as? String == "Configuration")
        let payload = try #require((profile["PayloadContent"] as? [[String: Any]])?.first)
        #expect(payload["PayloadType"] as? String == ManagedPreferences.domain)
        // Every non-payload key is a published key, at a value the catalog accepts.
        for (key, value) in payload where !key.hasPrefix("Payload") {
            #expect(CFManagedPreferenceReader.publishedKeys.contains(key))
            if let descriptor = SettingsSchema.all.first(where: { $0.id == key }), let json = ManagedPreferences.json(fromPropertyList: value) {
                #expect(descriptor.accepts(json))
            }
        }
    }

    @Test func intuneFileHasNoPlistWrapper() throws {
        let text = try ManagedPreferencesManifest.intunePreferenceFile()
        #expect(!text.contains("<plist"))
        #expect(!text.contains("<dict>\n<key>"))
        #expect(text.contains("<key>DisabledFeatures</key>"))
    }
}
