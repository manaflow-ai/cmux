import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// A fresh install's window starts on Glass (Leo, 2026-11-05: "new install should default to glass"),
/// unless cmux.json already names a window background or the Ghostty config gives a blur.
struct FreshInstallGlassTests {
    static func appearance(_ keys: [String: JSONValue]) -> JSONValue {
        .object(["appearance": .object(keys)])
    }

    @Test func anEmptyConfigStartsOnGlass() {
        let edits = WindowBackgroundSetting.freshInstallEdits(in: .object([:]), ghosttyMaterial: .unblurred)
        #expect(edits.count == 1)
        #expect(edits.first?.path == WindowBackgroundSetting.materialPath)
        #expect(edits.first?.value == .string("glass"))
        #expect(WindowMaterialChoice(rawValue: "glass") == WindowBackgroundSetting.freshInstallMaterial)
    }

    @Test func glassMakesAnOpaqueGhosttyWindowTranslucent() {
        let override = WindowBackgroundOverride(opacity: nil, material: WindowBackgroundSetting.freshInstallMaterial)
        let resolved = override.resolved(backgroundOpacity: 1, backgroundBlur: 0)
        #expect(resolved.backgroundOpacity < 1)
        #expect(resolved.backgroundBlur == -1)
    }

    @Test func aWindowBackgroundInTheFileIsKept() {
        for keys: [String: JSONValue] in [["backgroundBlur": .string("none")], ["backgroundOpacity": .number(1)]] {
            #expect(WindowBackgroundSetting.freshInstallEdits(in: Self.appearance(keys), ghosttyMaterial: .unblurred).isEmpty)
        }
    }

    @Test func aGhosttyBlurIsKept() {
        for material: WindowMaterialChoice in [.frosted, .glass, .glassClear] {
            #expect(WindowBackgroundSetting.freshInstallEdits(in: .object([:]), ghosttyMaterial: material).isEmpty)
        }
    }

    static func scratchHome() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cn-fresh-glass-\(UUID().uuidString)")
    }

    /// Every channel (NIGHTLY, RC, a tagged DEV) shares cmux-next.json, so only a launch that makes the
    /// file from nothing is a fresh install; a new channel's own first launch on an existing install is not.
    @Test func onlyALaunchThatMakesTheSharedFileIsFresh() throws {
        let home = Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try CmuxConfigFile.prepareLaunchFile(home: home, environment: [:])
        #expect(first.createdEmpty)
        let otherChannel = try CmuxConfigFile.prepareLaunchFile(home: home, environment: [:])
        #expect(!otherChannel.createdEmpty)
        #expect(otherChannel.url == first.url)
    }

    @Test func aClassicInstallIsNotFresh() throws {
        let home = Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".config/cmux")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: config.appending(path: "cmux.json"))
        #expect(try !CmuxConfigFile.prepareLaunchFile(home: home, environment: [:]).createdEmpty)
    }

    @Test func anOverriddenFileIsNeverFresh() throws {
        let home = Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let override = home.appending(path: "tagged.json").path
        #expect(try !CmuxConfigFile.prepareLaunchFile(home: home, environment: [CmuxConfigFile.overrideKey: override]).createdEmpty)
    }
}
