import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Coordinator decision PAGE-PREFS: the diff page's prefs are `diff.*`
/// settings and its "Viewed" marks live next to the recents; the page reaches
/// both through `cmux.diff.prefs.*` and `cmux.diff.viewed.*`, never web
/// storage. The diff page draws at the display's full rate.
@MainActor
@Suite(.serialized)
struct DiffPageStoresTests {
    final class MemoryPrefs: DiffPrefsStoring {
        var values: [String: JSONValue] = [:]
        func prefs() -> [String: JSONValue] { values }
        func setPref(_ key: String, to value: JSONValue) async throws {
            if value == .null { values.removeValue(forKey: key) } else { values[key] = value }
        }
    }

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-diff-stores-\(UUID().uuidString)/\(name)")
    }

    static func world() throws -> (DiffPageProvider, MemoryPrefs, DiffViewedFiles, DiffPageProviderTests.World) {
        let (provider, prefs, viewed, _, base) = try worldWithCollapsed()
        return (provider, prefs, viewed, base)
    }

    static func worldWithCollapsed() throws -> (DiffPageProvider, MemoryPrefs, DiffViewedFiles, DiffCollapsedFiles, DiffPageProviderTests.World) {
        let base = try DiffPageProviderTests.world()
        let prefs = MemoryPrefs()
        let viewedURL = temporaryURL(DiffViewedFiles.fileName)
        let viewed = DiffViewedFiles(url: viewedURL)
        let collapsed = DiffCollapsedFiles(url: DiffCollapsedFiles.standardURL(viewed: viewedURL))
        let provider = DiffPageProvider(ready: base.ready, sidecar: base.sidecar, languages: nil,
                                        stores: DiffPageStores(prefs: prefs, viewed: viewed, collapsed: collapsed))
        return (provider, prefs, viewed, collapsed, base)
    }

    static func call(_ provider: DiffPageProvider, _ op: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await DiffPageProviderTests.call(provider, op, params)
    }

    @Test func prefKeysAcceptOnlyThePagesValues() {
        #expect(DiffPrefKey.all.sorted() == ["collapsedFiles", "diffIndicators", "expandUnchanged", "layout", "lineNumbers",
                                             "showBackgrounds", "wordDiffs", "wordWrap"])
        // P2-3: every display key is a schema row; collapsedFiles is not a setting (P2-4).
        #expect(DiffPrefKey.displayKeys.sorted() == ["diffIndicators", "expandUnchanged", "layout", "lineNumbers",
                                                     "showBackgrounds", "wordDiffs", "wordWrap"])
        for key in DiffPrefKey.displayKeys { #expect(SettingsSchema.descriptor(for: DiffPrefKey.path(key)) != nil, "\(key)") }
        #expect(DiffPrefKey.accepts("wordWrap", true))
        #expect(!DiffPrefKey.accepts("wordWrap", "yes"))
        #expect(DiffPrefKey.accepts("layout", "unified"))
        #expect(!DiffPrefKey.accepts("layout", "stacked"))
        #expect(DiffPrefKey.accepts("collapsedFiles", ["/r\u{0}a.swift"]))
        #expect(!DiffPrefKey.accepts("collapsedFiles", ["no separator"]))
        #expect(DiffPrefKey.accepts("lineNumbers", .null))
        #expect(!DiffPrefKey.accepts("theme", true))
        #expect(DiffPrefKey.sanitized(["wordWrap": true, "layout": "stacked", "other": 1]) == ["wordWrap": true])
    }

    @Test func prefsGoThroughTheOpsAndSeedTheConfig() async throws {
        let (provider, prefs, _, _) = try Self.world()
        #expect(try await Self.call(provider, "cmux.diff.prefs.get") == ["prefs": .object([:])])
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "wordWrap", "value": true])
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "layout", "value": "unified"])
        #expect(prefs.values == ["wordWrap": true, "layout": "unified"])
        await #expect(throws: PageError.invalidParams("unknown pref or value")) {
            try await Self.call(provider, "cmux.diff.prefs.set", ["key": "wordWrap", "value": "on"])
        }
        let config = try await Self.call(provider, "cmux.diff.config")
        #expect(config["payload"]?["viewerOptions"] == ["wordWrap": true, "layout": "unified"])
        #expect(config["payload"]?["layout"] == "unified")
        let ops = config["ops"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(ops == DiffPageProvider.storeOps)
        #expect(!ops.contains("cmux.diff.comments"))
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "wordWrap", "value": .null])
        #expect(prefs.values == ["layout": "unified"])
        await provider.close()
    }

    @Test func viewedMarksAreThisTabsRepositoryOnly() async throws {
        let (provider, _, viewed, base) = try Self.world()
        let scope: JSONValue = ["repoRoot": .string(base.repo), "source": "branch:origin/main"]
        _ = try await Self.call(provider, "cmux.diff.viewed.set", ["scope": scope, "file": ["path": "a.swift", "fingerprint": "f1"]])
        _ = try await Self.call(provider, "cmux.diff.viewed.set", ["scope": scope, "file": ["path": "b.swift", "fingerprint": "f2"]])
        _ = try await Self.call(provider, "cmux.diff.viewed.clear", ["scope": scope, "path": "a.swift"])
        let listed = try await Self.call(provider, "cmux.diff.viewed.list", ["scope": scope])
        #expect(listed == ["files": [["path": "b.swift", "fingerprint": "f2"]]])
        await #expect(throws: PageError(code: "notAllowed", message: "Not this tab's repository")) {
            try await Self.call(provider, "cmux.diff.viewed.list", ["scope": ["repoRoot": "/elsewhere", "source": "staged"]])
        }
        await viewed.flush()
        let reread = DiffViewedFiles(url: viewed.url)
        #expect(await reread.list(DiffViewedFiles.key(repoRoot: base.repo, source: "branch:origin/main")) == [.init(path: "b.swift", fingerprint: "f2")])
        await provider.close()
    }

    @Test func aTabWithoutStoresServesNoStoreOp() async throws {
        let base = try DiffPageProviderTests.world()
        await #expect(throws: PageError.unknownOp("cmux.diff.prefs.get")) { try await Self.call(base.provider, "cmux.diff.prefs.get") }
        let config = try await Self.call(base.provider, "cmux.diff.config")
        #expect(config["ops"] == .array([]))
        await base.provider.close()
    }

    /// P2-4: the collapsed files are not in cmux.json: the page sets them through the same prefs op,
    /// and the host keeps them in its store next to the viewed marks.
    @Test func collapsedFilesLiveNextToTheViewedMarks() async throws {
        let (provider, prefs, viewed, collapsed, _) = try Self.worldWithCollapsed()
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "collapsedFiles", "value": ["/r\u{0}a.swift"]])
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "wordWrap", "value": true])
        #expect(prefs.values == ["wordWrap": true], "the settings store never sees collapsedFiles")
        #expect(try await Self.call(provider, "cmux.diff.prefs.get") == ["prefs": ["wordWrap": true, "collapsedFiles": ["/r\u{0}a.swift"]]])
        #expect(collapsed.url.deletingLastPathComponent() == viewed.url.deletingLastPathComponent())
        await collapsed.flush()
        #expect(await DiffCollapsedFiles(url: collapsed.url).list() == ["/r\u{0}a.swift"])
        _ = try await Self.call(provider, "cmux.diff.prefs.set", ["key": "collapsedFiles", "value": .null])
        #expect(try await Self.call(provider, "cmux.diff.prefs.get") == ["prefs": ["wordWrap": true]])
        await provider.close()
    }

    @Test func viewedScopesAreCapped() async throws {
        let viewed = DiffViewedFiles(url: Self.temporaryURL(DiffViewedFiles.fileName))
        for index in 0..<(DiffViewedFiles.scopeLimit + 3) {
            await viewed.set(.init(path: "a", fingerprint: "f"), in: "scope-\(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(await viewed.list("scope-0").isEmpty)
        #expect(await viewed.list("scope-\(DiffViewedFiles.scopeLimit + 2)").count == 1)
    }

    /// The real store: `diff.*` in cmux.json, readable at once and after a reload.
    @Test func settingsPrefsWriteTheDiffSection() async throws {
        let url = Self.temporaryURL("cmux.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        await settings.reload()
        let prefs = SettingsDiffPrefs { settings }
        try await prefs.setPref("wordWrap", to: true)
        #expect(prefs.prefs() == ["wordWrap": true])
        await settings.reload()
        #expect(settings.fileRoot["diff"]?["wordWrap"] == true)
        // P2-3: only schema rows go through the settings store; there is no raw file write.
        await #expect(throws: SettingsDiffPrefs.NotASetting.self) { try await prefs.setPref("collapsedFiles", to: ["/r\u{0}a.swift"]) }
        try await prefs.setPref("wordWrap", to: .null)
        await settings.reload()
        #expect(prefs.prefs().isEmpty)
    }

    @Test func theDiffPageDrawsAtTheFullFrameRate() {
        #expect(DiffPageService.engineOptions == PageEngineOptions(fullFrameRate: true))
    }
}
