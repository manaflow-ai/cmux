import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The settings file's root never crosses the Rust bridge whole per row (thread p1795759419: a
/// 157 KB cmux-next.json JSON-encoded per call was a 2-6 s main-thread hang). The Settings page's
/// rows ask `isCustomized` for every key the file sets; each asked `theme.exceptions` with the
/// whole file. With the cut, a rules call carries only the key it reads.
@MainActor @Suite(.serialized) struct SettingsFileRootBridgeCostTests {
    /// A file that sets every schema key to its default, padded to about 160 KB (Lawrence's is 157 KB).
    static func bigFile() -> JSONValue {
        var root = JSONValue.object([:])
        for descriptor in SettingsSchema.all {
            guard let value = descriptor.defaultValue else { continue }
            root = root.setting(value, at: descriptor.path)
        }
        let padding = (0..<2_000).map { JSONValue.string("padding-entry-\($0)-" + String(repeating: "x", count: 56)) }
        return root.setting(.array(padding), at: ["zzPadding"])
    }

    @Test func pageRowsDoNotEncodeTheWholeFilePerRow() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-fileroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        let text = Self.bigFile().compactText
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences(forced: [:])), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.fileRoot["zzPadding"] != nil)
        let stored = SettingsSchema.all.filter { $0.storedValue(in: settings.fileRoot) != nil }.count
        let clock = ContinuousClock()
        let runs = 5
        var rows = 0
        let elapsed = clock.measure {
            for _ in 0..<runs { rows = settings.pageRows(section: nil) { _ in .null }.arrayValue?.count ?? 0 }
        }
        let perCall = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("FILEROOT-BRIDGE pageRows: file \(text.utf8.count / 1024) KB, \(rows) rows, \(stored) stored keys: \(String(format: "%.1f", perCall / Double(runs))) ms per call")
        let theme = clock.measure { for _ in 0..<1_100 { _ = ThemeFileSetting.name(in: settings.fileRoot); _ = ThemeFileExceptionsSetting.keys(in: settings.fileRoot) } }
        print("FILEROOT-BRIDGE theme.name+exceptions x1100: \(theme)")
        let looks = clock.measure { for _ in 0..<1_100 { _ = BackdropSelectionSetting.previous(in: settings.fileRoot) } }
        print("FILEROOT-BRIDGE backdrop.previous x1100: \(looks)")
        // Same harness, before and after: the old per-row call sent the whole root (one per row),
        // the cut sends only the key `theme.exceptions` reads.
        let whole = clock.measure { for _ in 0..<rows { _ = SettingsRust.answer("theme.exceptions", .object(["root": settings.fileRoot])) } }
        let cut = clock.measure { for _ in 0..<rows { _ = ThemeFileExceptionsSetting.keys(in: settings.fileRoot) } }
        print("FILEROOT-BRIDGE per-row exceptions x\(rows): before (whole root) \(whole), after (kept keys) \(cut)")
        // Duress: the same page pass while four detached tasks encode the file in a loop.
        let stop = ManagedAtomicFlag()
        let load = (0..<4).map { _ in Task.detached { [text] in while !stop.isSet { _ = text.utf8.reduce(0) { $0 &+ Int($1) } } } }
        let underLoad = clock.measure { for _ in 0..<runs { _ = settings.pageRows(section: nil) { _ in .null } } }
        stop.set()
        for task in load { await task.value }
        print("FILEROOT-BRIDGE pageRows under 4-core load: \(underLoad / runs) per call")
        #expect(perCall / Double(runs) < 100, "pageRows over a 160 KB file: \(perCall / Double(runs)) ms")
        #expect(underLoad / runs < .milliseconds(200))
        #expect(theme < .milliseconds(200))
        #expect(looks < .milliseconds(200))
    }

    @Test func keepingHoldsOnlyTheKeysARuleReads() {
        let root: JSONValue = ["appearance": ["themeFile": "Dusk", "themeFileExceptions": ["appearance.accent"], "accent": "red"], "other": ["big": "x"]]
        #expect(root.keeping([ThemeFileSetting.configPath]) == ["appearance": ["themeFile": "Dusk"]])
        #expect(root.keeping([["nope", "missing"]]) == .object([:]))
        #expect(ThemeFileSetting.name(in: root.keeping([ThemeFileSetting.configPath])) == ThemeFileSetting.name(in: root))
    }
}

/// A stop flag the load tasks read off the main actor.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
