import Foundation
import Testing
@testable import CmuxNextBrowser

/// GHSA-cmqw-9r2w-6wv2: uBlock Origin 1.75.2 and older let a website frame and drive the
/// element picker and add trusted filters (universal XSS). A person's own uBlock Origin wins
/// over the built-in copy, and nothing updates it (the MV2 build is off the Web Store), so a
/// person's copy below the floor must not keep the fixed built-in copy from loading.
@Suite struct CEFBuiltInAdBlockerFloorTests {
    private let resources = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Resources")
    private let id = CEFBuiltInExtensions.adBlockerID

    private func profiles(entry: [String: Any], unpackedManifestVersion: String? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ubo-floor-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("Profile-TEST")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let prefs: [String: Any] = ["extensions": ["settings": [id: entry]]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: profile.appendingPathComponent("Secure Preferences"))
        let unpacked = root.appendingPathComponent("my-ublock")
        if let version = unpackedManifestVersion {
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": "uBlock Origin", "version": version])
                .write(to: unpacked.appendingPathComponent("manifest.json"))
        }
        return (root, unpacked)
    }

    private func loadsBuiltIn(_ root: URL) -> Bool {
        CEFBuiltInExtensions(adBlockerEnabled: true)
            .plan(resources: resources, profiles: root, fileExists: { _ in true }).folders.count == 1
    }

    @Test func bundledFloorIsThePatchedRelease() {
        #expect(CEFBuiltInExtensions.isAtLeast(CEFBuiltInExtensions.adBlockerMinimumVersion, "1.75.4"))
        #expect(!CEFBuiltInExtensions.isAtLeast("1.75.2", CEFBuiltInExtensions.adBlockerMinimumVersion))
        #expect(!CEFBuiltInExtensions.isAtLeast("1.75.0", "1.76.0"))
        #expect(CEFBuiltInExtensions.isAtLeast("1.76.4", "1.76.0"))
        #expect(CEFBuiltInExtensions.isAtLeast("1.100.0", "1.76.0"))
        #expect(CEFBuiltInExtensions.isAtLeast("1.76", "1.76.0"))
    }

    @Test func vulnerableInstalledCopyGivesWayToTheBuiltInOne() throws {
        let (root, _) = try profiles(entry: ["path": "\(id)/1.75.0_0", "location": 1])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CEFBuiltInExtensions.personAdBlocker(profiles: root) == nil)
        #expect(loadsBuiltIn(root))
    }

    @Test func patchedInstalledCopyStillWins() throws {
        let (root, _) = try profiles(entry: ["path": "\(id)/1.76.4_0", "location": 1])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CEFBuiltInExtensions.personAdBlocker(profiles: root) == 1)
        #expect(!loadsBuiltIn(root))
    }

    @Test func vulnerableUnpackedCopyGivesWayToTheBuiltInOne() throws {
        let (root, unpacked) = try profiles(entry: [:], unpackedManifestVersion: "1.75.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs: [String: Any] = ["extensions": ["settings": [id: ["path": unpacked.path, "location": 4]]]]
        try JSONSerialization.data(withJSONObject: prefs)
            .write(to: root.appendingPathComponent("Profile-TEST/Secure Preferences"))
        #expect(CEFBuiltInExtensions.personAdBlocker(profiles: root) == nil)
        #expect(loadsBuiltIn(root))
    }

    @Test func entryManifestVersionCounts() throws {
        let (root, _) = try profiles(entry: ["path": "\(id)/x", "location": 1, "manifest": ["version": "1.74.0"]])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(loadsBuiltIn(root))
    }

    @Test func unknownVersionKeepsThePersonsCopy() throws {
        let (root, _) = try profiles(entry: ["path": "/nowhere/ublock", "location": 4])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(CEFBuiltInExtensions.personAdBlocker(profiles: root) == 4)
        #expect(!loadsBuiltIn(root))
    }
}
