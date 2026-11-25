@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// `app.language` applied: a code becomes the app's own `AppleLanguages` (what menus and `Bundle`
/// read at the next launch) and goes to the pages; System takes back cmux's write and only that, and
/// puts back the per-app language it replaced. Every
/// test writes a throwaway suite, never the real app domain.
@MainActor
struct AppLanguageApplierTests {
    private final class Suite {
        let name: String
        let defaults: UserDefaults
        init() throws {
            let name = "app-language-\(UUID().uuidString)"
            self.name = name
            defaults = try #require(UserDefaults(suiteName: name))
        }
        /// What the suite's own domain holds (`stringArray(forKey:)` falls back to the global domain).
        var languages: [String]? { defaults.persistentDomain(forName: name)?[AppLanguageApplier.languagesKey] as? [String] }
        var applied: Any? { defaults.persistentDomain(forName: name)?[AppLanguageApplier.appliedKey] }
        func remove() { defaults.removePersistentDomain(forName: name) }
    }

    @Test func aCodeIsWrittenAndPushedToThePages() throws {
        let suite = try Suite()
        defer { suite.remove() }
        var pushed: [String?] = []
        let applier = AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { pushed.append($0) }
        applier.apply("ja")
        #expect(suite.languages == ["ja"])
        #expect(pushed == ["ja"])
    }

    @Test func systemRemovesCmuxsOwnWrite() throws {
        let suite = try Suite()
        defer { suite.remove() }
        var pushed: [String?] = []
        let applier = AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { pushed.append($0) }
        applier.apply("de")
        applier.apply(nil)
        #expect(suite.languages == nil)
        #expect(suite.applied == nil)
        #expect(pushed == ["de", nil])
    }

    @Test func systemKeepsAPerAppLanguageCmuxDidNotWrite() throws {
        let suite = try Suite()
        defer { suite.remove() }
        // macOS System Settings > Language & Region > Applications set French for cmux.
        suite.defaults.set(["fr"], forKey: AppLanguageApplier.languagesKey)
        AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { _ in }.apply(nil)
        #expect(suite.languages == ["fr"])
    }

    @Test func systemPutsBackThePerAppLanguageCmuxReplaced() throws {
        let suite = try Suite()
        defer { suite.remove() }
        // French picked in macOS System Settings, then two cmux picks, then System.
        suite.defaults.set(["fr"], forKey: AppLanguageApplier.languagesKey)
        let applier = AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { _ in }
        applier.apply("de")
        applier.apply("ko")
        #expect(suite.languages == ["ko"])
        // A relaunch makes a new applier; what it replaced is in defaults, not in memory.
        AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { _ in }.apply(nil)
        #expect(suite.languages == ["fr"])
        #expect(suite.applied == nil)
        #expect(suite.defaults.persistentDomain(forName: suite.name)?[AppLanguageApplier.previousKey] == nil)
    }

    @Test func systemKeepsAPerAppLanguagePickedAfterCmuxsWrite() throws {
        let suite = try Suite()
        defer { suite.remove() }
        suite.defaults.set(["fr"], forKey: AppLanguageApplier.languagesKey)
        let applier = AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { _ in }
        applier.apply("de")
        // Spanish picked in macOS System Settings while cmux's German was on.
        suite.defaults.set(["es"], forKey: AppLanguageApplier.languagesKey)
        applier.apply(nil)
        #expect(suite.languages == ["es"])
    }

    @Test func aNewCodeReplacesTheLastOne() throws {
        let suite = try Suite()
        defer { suite.remove() }
        let applier = AppLanguageApplier(defaults: suite.defaults, domain: suite.name) { _ in }
        applier.apply("ko")
        applier.apply("zh-Hans")
        #expect(suite.languages == ["zh-Hans"])
        applier.apply(nil)
        #expect(suite.languages == nil)
    }

    @Test func thePageScriptHandsTheCodeOrNull() {
        #expect(PageWebView.languageScript("pt-BR") == #"window.__cmuxSetAppLanguage?.("pt-BR", false);"#)
        #expect(PageWebView.languageScript(nil) == "window.__cmuxSetAppLanguage?.(null, false);")
        #expect(PageWebView.languageScript("fr", refresh: true) == #"window.__cmuxSetAppLanguage?.("fr", true);"#)
    }
}
