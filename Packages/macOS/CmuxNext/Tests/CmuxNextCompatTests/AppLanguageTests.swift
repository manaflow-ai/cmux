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

        /// Write a bundle with these `.lproj` string tables (`Localizable`) and return its URL.
        /// Keeping creation separate lets tests instantiate a subclass before Foundation caches a
        /// plain `Bundle` for the same path.
        func bundleURL(_ tables: [String: [String: String]], name: String = "Strings.bundle", in folder: URL? = nil) throws -> URL {
            let url = (folder ?? root).appending(path: name, directoryHint: .isDirectory)
            for (language, strings) in tables {
                let lproj = url.appending(path: "\(language).lproj", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                let body = strings.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
                try Data(body.utf8).write(to: lproj.appending(path: "Localizable.strings"))
            }
            return url
        }

        /// A bundle with these `.lproj` string tables (`Localizable`).
        func bundle(_ tables: [String: [String: String]], name: String = "Strings.bundle", in folder: URL? = nil) throws -> Bundle {
            let url = try bundleURL(tables, name: name, in: folder)
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

    nonisolated private final class StartFlag: Sendable {
        let value = Mutex(0)
    }

    /// Count the expensive Foundation boundary, not the cache's implementation. In particular,
    /// equal returned bundle identities alone cannot detect repeatedly resolving the same path.
    nonisolated private final class ResolutionCountingBundle: Bundle, @unchecked Sendable {
        let reads = Mutex<[String: Int]>([:])

        private func record(_ operation: String) {
            reads.withLock { $0[operation, default: 0] += 1 }
        }

        override var bundleURL: URL {
            record("bundleURL")
            return super.bundleURL
        }

        override var bundlePath: String {
            record("bundlePath")
            return super.bundlePath
        }

        override var localizations: [String] {
            record("localizations")
            return super.localizations
        }

        override func path(forResource name: String?, ofType ext: String?) -> String? {
            record("resourcePath")
            return super.path(forResource: name, ofType: ext)
        }
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

    /// Every native string read resolves its bundle on the main thread (hq#22770: 2-4 s hangs in
    /// `languagePackCopy`): the answer is cached, and a pack that becomes active or goes away is
    /// read at once after the language hears of it.
    @Test func theResolvedBundleIsCachedAndFollowsAPackChange() throws {
        let scratch = try Scratch()
        let name = "Cached-\(UUID().uuidString).bundle"
        let bundle = try scratch.bundle(["en": Self.english], name: name)
        let packRoot = scratch.root.appending(path: "pack", directoryHint: .isDirectory)
        let packCopy = try scratch.bundle(["ja": ["greeting": "こんにちは"]], name: name, in: packRoot)
        defer { Bundle.deactivateLanguagePack() }
        let language = AppLanguage()
        language.adopt(bundle)
        #expect(bundle.languagePackCopy == nil)
        #expect(bundle.inAppLanguage === bundle)
        #expect(bundle.inAppLanguage === bundle.inAppLanguage)

        Bundle.activateLanguagePack(root: packRoot)
        language.languagePackChanged()
        #expect(bundle.languagePackCopy?.bundleURL.standardizedFileURL == packCopy.bundleURL.standardizedFileURL)
        #expect(bundle.inAppLanguage === bundle.languagePackCopy)
        Bundle.deactivateLanguagePack()
        language.languagePackChanged()
        #expect(bundle.languagePackCopy == nil)
        #expect(bundle.inAppLanguage === bundle)
    }

    /// f91b413573: a native view can resolve many strings in one redraw. Once warm, both System
    /// and an explicit language must do zero path/localization work at 1x, 4x and 10x volume.
    @Test(arguments: [1, 4, 10]) func warmLookupsDoNotResolveBundlePaths(scale: Int) throws {
        let scratch = try Scratch()
        let fixture = try scratch.bundleURL(Self.tables)
        let bundle = try #require(ResolutionCountingBundle(path: fixture.path))
        let language = AppLanguage()
        language.adopt(bundle)
        for code in [nil, "ja", "de", nil] as [String?] {
            language.set(code)
            let answer = bundle.inAppLanguage
            let cold = bundle.reads.withLock { reads in
                let result = reads
                reads = [:]
                return result
            }
            // Prove the spy sees real resolution, including invalidation on a language change.
            #expect(cold["bundlePath", default: 0] + cold["bundleURL", default: 0] > 0)
            if code != nil {
                #expect(cold["localizations", default: 0] > 0)
                #expect(cold["resourcePath", default: 0] > 0)
            }
            var matched = 0
            for _ in 0 ..< 1_000 * scale {
                if bundle.inAppLanguage === answer { matched += 1 }
            }
            #expect(matched == 1_000 * scale)
            #expect(bundle.reads.withLock { $0 }.isEmpty)
        }
    }

    /// Executable duress measurement: real (uninstrumented) bundle reads on the main actor
    /// alongside four concurrent readers. Timing is reported, not a scheduler-dependent gate.
    @MainActor @Test(arguments: [1, 4, 10]) func warmLookupsUnderConcurrentReaders(scale: Int) async throws {
        let scratch = try Scratch()
        let bundle = try scratch.bundle(Self.tables)
        let language = AppLanguage()
        language.adopt(bundle)
        language.set("ja")
        let answer = bundle.inAppLanguage
        let count = 10_000 * scale
        let started = StartFlag()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    started.value.withLock { $0 += 1 }
                    var matched = 0
                    for _ in 0 ..< count {
                        if bundle.inAppLanguage === answer { matched += 1 }
                    }
                    return matched
                }
            }
            // Do not start the main-actor clock until every reader has entered its loop.
            while started.value.withLock({ $0 }) < 4 { await Task.yield() }
            let clock = ContinuousClock()
            let start = clock.now
            var matched = 0
            for _ in 0 ..< count {
                if bundle.inAppLanguage === answer { matched += 1 }
            }
            let elapsed = start.duration(to: clock.now)
            #expect(matched == count)
            for await backgroundMatched in group { #expect(backgroundMatched == count) }
            print("LANGUAGE_LOOKUP_DURESS scale=\(scale) main_reads=\(count) background_readers=4 background_reads=\(count * 4) main_elapsed=\(elapsed)")
        }
    }
}
#endif
