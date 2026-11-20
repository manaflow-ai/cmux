import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `appearance.fontSmoothing`, the CSS model: `auto` (the default: the Mac's own smoothing for native
/// text, each page's own style for web text, the look cmux had before the setting), `antialiased`
/// (thin, grayscale) and `subpixel` (macOS font smoothing on). The first release's `system` reads
/// as `auto`; a bad value keeps the default and says why.
struct FontSmoothingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["fontSmoothing": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func autoByDefaultSoNothingChangesUntilThePersonPicks() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test(arguments: ["auto", "antialiased", "subpixel"])
    func eachCSSValueIsAChoice(_ value: String) {
        let snapshot = Self.parse(.string(value))
        #expect(snapshot.fontSmoothing.rawValue == value)
        #expect(snapshot.diagnostics.isEmpty, "\(value): \(snapshot.diagnostics)")
    }

    @Test func theFirstReleasesSystemValueReadsAsAuto() {
        let snapshot = Self.parse(.string("system"))
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test(arguments: [JSONValue.string("subpixel-antialiased-ish"), .bool(true), .number(0)])
    func aBadValueKeepsTheDefaultAndSaysWhy(_ value: JSONValue) {
        let snapshot = Self.parse(value)
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.fontSmoothing" }, "\(snapshot.diagnostics)")
    }

    /// AppKit reads a saved value as it starts, so a change made while cmux was not running is
    /// written from the file before `NSApplication` exists, over the last launch's value.
    @Test(arguments: [("subpixel", 0, 2), ("antialiased", 2, 0), (nil, 0, nil)] as [(String?, Int, Int?)])
    func theFileIsWrittenBeforeAppKitStarts(_ mode: String?, saved: Int, expected: Int?) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux.json")
        if let mode { try Data(#"{"appearance": {"fontSmoothing": "\#(mode)"}}"#.utf8).write(to: file) }
        let suite = "fs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: ProcessFontSmoothing.defaultsKey)

        let written = FontSmoothingSetting.applyBeforeLaunch(fileURL: file, managed: FixedManagedPreferenceReader(ManagedPreferences()),
                                                             defaults: defaults)

        #expect(written.rawValue == (mode ?? "auto"))
        #expect((defaults.object(forKey: ProcessFontSmoothing.defaultsKey) as? NSNumber)?.intValue == expected)
    }

    /// CMUX-631: `main` runs this before AppKit reports the launch finished, so every ms here is the Dock's
    /// bounce. Its managed reader names only this key: the default reader's key list builds the whole settings
    /// catalog, 51 ms of `main`'s 69 on the 2026-11-19 nightly (launch-ready profile step 77b0c9f1).
    @Test func theLaunchReaderReadsOnlyThisKey() throws {
        let reader = try #require(ManagedPreferenceLocation.defaultReader(environment: [:], keys: ["appearance.fontSmoothing"])
            as? ChromePolicyManagedPreferenceReader)
        let cmux = try #require(reader.cmux as? CFManagedPreferenceReader)
        #expect(cmux.keys == ["appearance.fontSmoothing"])
        let full = try #require(ManagedPreferenceLocation.defaultReader(environment: [:]) as? ChromePolicyManagedPreferenceReader)
        #expect((full.cmux as? CFManagedPreferenceReader)?.keys == CFManagedPreferenceReader.readKeys, "no keys: every published key, as before")
    }

    /// The merge `main` runs has no team layer: limiting an empty one to the catalog returns it unchanged
    /// (and builds no catalog); a layer with keys is still limited.
    @Test func anEmptyTeamLayerIsNotLimited() {
        #expect(TeamPolicyLayer.none.limitedToCatalog() == .none)
        let layer = TeamPolicyLayer(defaults: ["appearance.fontSmoothing": .string("subpixel"), "notASetting.x": .bool(true)])
        #expect(layer.limitedToCatalog().defaults.keys.sorted() == ["appearance.fontSmoothing"])
    }

    /// A forced MDM value still wins over the file before AppKit starts.
    @Test func aForcedManagedValueWinsOverTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux.json")
        try Data(#"{"appearance": {"fontSmoothing": "subpixel"}}"#.utf8).write(to: file)
        let suite = "fs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let managed = ManagedPreferences(forced: ["appearance.fontSmoothing": .string("antialiased")], recommended: [:])

        let written = FontSmoothingSetting.applyBeforeLaunch(fileURL: file, managed: FixedManagedPreferenceReader(managed), defaults: defaults)

        #expect(written.rawValue == "antialiased")
    }
}
