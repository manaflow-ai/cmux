#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAppearance
import CmuxNextSettings
import CryptoKit
import Foundation
import Testing

/// What the oracle's settings facet (p15-oracle-039) records of an applied snapshot: the sha256 of the effective
/// document as canonical JSON (the runner's form) and the catalog keys set to a value other than their default.
/// Run: `swift test --filter CmuxConfigSnapshotOracleDigestTests`.
struct CmuxConfigSnapshotOracleDigestTests {
    private func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    /// The lowercase hex sha256 of `text`'s UTF-8, computed apart from the encoder under test.
    private func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func defaultsHashTheEmptyObjectAndListNoKey() {
        let defaults = snapshot(.object([:]))
        // python3 -c 'import hashlib; print(hashlib.sha256(b"{}").hexdigest())'
        #expect(defaults.effectiveSha256 == "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        #expect(defaults.nonDefaultKeys().isEmpty)
    }

    @Test func theHashIsOfSortedKeysWithNoWhitespace() {
        let changed = snapshot(["ui": ["animations": ["enabled": false], "animationSpeed": "normal"]])
        #expect(changed.effectiveSha256 == "sha256:" + hex(#"{"ui":{"animationSpeed":"normal","animations":{"enabled":false}}}"#))
        #expect(changed.nonDefaultKeys() == ["ui.animationSpeed", "ui.animations.enabled"])
    }

    @Test func aSettingWrittenAsItsDefaultIsNotListedButChangesTheHash() throws {
        let enabled = try #require(SettingsSchema.descriptor(for: MotionCategoriesSetting.enabledPath)?.defaultValue)
        let written = snapshot(["ui": ["animations": ["enabled": enabled]]])
        #expect(written.nonDefaultKeys().isEmpty)
        #expect(written.effectiveSha256 != snapshot(.object([:])).effectiveSha256)
    }

    @Test func keysOutsideTheCatalogOnlyChangeTheHash() {
        let custom = snapshot(["actions": ["deploy": ["command": "ssh prod ./deploy"]]])
        #expect(custom.nonDefaultKeys().isEmpty)
        #expect(custom.effectiveSha256 != snapshot(.object([:])).effectiveSha256)
    }

    /// A renamed key's old key still applies while the new key is absent, so the new key is listed, as the
    /// Settings row shows Reset for it.
    @Test func aRenamedKeysOldKeyListsTheNewKey() throws {
        let art = try #require(BackdropArt.allCases.first { $0 != BackdropSelectionSetting.defaultArt }).rawValue
        let legacy = snapshot(["appearance": ["backdropArt": .string(art)]])
        #expect(legacy.backdropArt?.rawValue == art)
        #expect(legacy.nonDefaultKeys().contains("appearance.background"))
    }

    @Test func aSettingWithARunTimeDefaultCountsWhenSet() {
        let derived = SettingDescriptor(["appearance", "derived"], section: .appearance, group: "g", title: "t",
                                        kind: .color, default: nil)
        let set = snapshot(["appearance": ["derived": "x"]])
        #expect(set.nonDefaultKeys(in: [derived]) == ["appearance.derived"])
        #expect(snapshot(.object([:])).nonDefaultKeys(in: [derived]).isEmpty)
    }
}
#endif
