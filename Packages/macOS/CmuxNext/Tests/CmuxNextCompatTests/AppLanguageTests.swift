#if canImport(ObjectiveC)
@testable import CmuxNextCompat
import Foundation
import Observation
import Testing

/// `app.language` switches cmux's native text live: `String(localized:bundle:)` given an adopted
/// bundle's ``Foundation/Bundle/inAppLanguage`` (what every module's `Bundle.localizedModule` is)
/// answers in the chosen language at once, System gives the bundle's own answer again, and a lookup
/// made in an observation scope runs again on a change (what re-renders a view).
///
/// Each test has its own ``AppLanguage`` and adopts a copy of a bundle of its own in a temporary
/// folder, never a bundle another test reads. The first version overrode the bundle class's
/// `localizedString(forKey:value:table:)` instead; `String(localized:)` never called it on macOS 26
/// (fleet job d8f82cb0, 4 failures here), so these lookups stayed in the launch language.
@Suite(.serialized)
struct AppLanguageTests {
    /// A test's own copy of a bundle, removed when the test ends.
    nonisolated private final class Scratch {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "app-language-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// A bundle with these `.lproj` string tables (`Localizable`).
        func bundle(_ tables: [String: [String: String]], name: String = "Strings.bundle", in folder: URL? = nil) throws -> Bundle {
            let url = (folder ?? root).appending(path: name, directoryHint: .isDirectory)
            for (language, strings) in tables {
                let lproj = url.appending(path: "\(language).lproj", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                let body = strings.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
                try Data(body.utf8).write(to: lproj.appending(path: "Localizable.strings"))
            }
            return try #require(Bundle(url: url))
        }

        /// A copy of one of cmux's own resource bundles, as the app ships it (the test products
        /// folder holds every package resource bundle beside the test bundle).
        func copyOfCmuxBundle(_ target: String) throws -> Bundle {
            let products = Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: products.path)
            let name = try #require(names.first { $0.hasSuffix("_\(target).bundle") }, "no \(target) resource bundle in \(products.path)")
            let copy = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: products.appending(path: name, directoryHint: .isDirectory), to: copy)
            return try #require(Bundle(url: copy))
        }
    }

    nonisolated private final class Flag: Sendable {
        let value = Mutex(false)
    }

    private static let english = ["greeting": "Hello", "only.english": "Only English"]
    private static let tables = ["en": english, "ja": ["greeting": "こんにちは"], "de": ["greeting": "Hallo"]]

    @Test func anAdoptedBundleAnswersInTheChosenLanguageAndSystemGivesItBack() throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let language = AppLanguage()
        language.adopt(bundle)
        let system = String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage)

        language.set("ja")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "こんにちは")
        language.set("de")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "Hallo")
        // A key the language lacks shows the text the code gives.
        #expect(String(localized: "only.english", defaultValue: "Only English", bundle: bundle.inAppLanguage) == "Only English")
        language.set(nil)
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == system)
    }

    @Test func aLanguageTheBundleDoesNotShipFallsBackToItsDevelopmentLanguage() throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let language = AppLanguage()
        language.adopt(bundle)
        language.set("ja")
        language.set("ko")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) != "こんにちは")
    }

    @Test func aBundleNotAdoptedKeepsItsLaunchLanguage() throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let language = AppLanguage()
        let system = String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage)
        language.set("ja")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == system)
    }

    @Test func aLookupInAnObservationScopeRunsAgainOnAChange() throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let language = AppLanguage()
        language.adopt(bundle)
        let changed = Flag()
        withObservationTracking {
            _ = String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage)
        } onChange: {
            changed.value.withLock { $0 = true }
        }
        language.set("ja")
        #expect(changed.value.withLock { $0 })
        #expect(language.code == "ja")
    }

    /// The app adopts the bundles the launch warm-up opened, and the modules read `Bundle.module`:
    /// NSBundle hands out one instance per path, so the adoption reaches the module's lookups.
    @Test func anotherInstanceForThePathSeesTheAdoption() throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let again = try #require(Bundle(url: bundle.bundleURL))
        #expect(again === bundle)
        let language = AppLanguage()
        language.adopt(bundle)
        language.set("ja")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: again.inAppLanguage) == "こんにちは")
    }

    /// A key of a real cmux string table (CmuxNextUpdater's sidebar "Did you know?" card heading).
    @Test func aCmuxStringSwitchesToJapaneseAndBack() throws {
        let scratch = try Scratch()
        let bundle = try scratch.copyOfCmuxBundle("CmuxNextUpdater")
        let japanese = try #require(bundle.url(forResource: "ja", withExtension: "lproj").flatMap(Bundle.init(url:)))
            .localizedString(forKey: "updater.tip.eyebrow", value: nil, table: nil)
        #expect(japanese != "Did you know?" && japanese != "updater.tip.eyebrow")
        let language = AppLanguage()
        language.adopt(bundle)
        let system = String(localized: "updater.tip.eyebrow", defaultValue: "Did you know?", bundle: bundle.inAppLanguage)

        language.set("ja")
        #expect(String(localized: "updater.tip.eyebrow", defaultValue: "Did you know?", bundle: bundle.inAppLanguage) == japanese)
        language.set(nil)
        #expect(String(localized: "updater.tip.eyebrow", defaultValue: "Did you know?", bundle: bundle.inAppLanguage) == system)
    }

    /// A NIGHTLY's bundle holds English only (CMUX-570); the downloaded pack's copy of it holds the
    /// chosen language, and the lookup reads it, live, once the pack is active.
    @Test func theChosenLanguageComesFromTheActiveLanguagePack() throws {
        let scratch = try Scratch()
        let name = "Pack-\(UUID().uuidString).bundle"
        let bundle = try scratch.bundle(["en": Self.english], name: name)
        let packRoot = scratch.root.appending(path: "pack", directoryHint: .isDirectory)
        _ = try scratch.bundle(["ja": ["greeting": "こんにちは"]], name: name, in: packRoot)
        defer { Bundle.deactivateLanguagePack() }
        let language = AppLanguage()
        language.adopt(bundle)
        language.set("ja")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "Hello")

        let changed = Flag()
        withObservationTracking {
            _ = String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage)
        } onChange: {
            changed.value.withLock { $0 = true }
        }
        Bundle.activateLanguagePack(root: packRoot)
        language.languagePackChanged()
        #expect(changed.value.withLock { $0 })
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "こんにちは")
        // English stays the bundle's own, and a language the pack does not hold never reads it.
        language.set("en")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "Hello")
        language.set("de")
        #expect(String(localized: "greeting", defaultValue: "Hello", bundle: bundle.inAppLanguage) == "Hello")
        // A language that needs no pack takes the pack away: System reads the bundle again.
        language.set(nil)
        Bundle.deactivateLanguagePack()
        #expect(bundle.inAppLanguage === bundle)
    }
}
#endif
