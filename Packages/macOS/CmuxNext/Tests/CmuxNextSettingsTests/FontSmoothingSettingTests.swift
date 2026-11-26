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
}
