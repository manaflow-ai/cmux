@testable import CmuxNextApp
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// `app.language` applied: a code becomes the app's own `AppleLanguages` (what menus and `Bundle`
/// read at the next launch) and goes to the pages; System removes cmux's write and only that. Every
/// test writes a throwaway suite, never the real app domain.
@MainActor
struct AppLanguageApplierTests {
    private final class Suite {
        let name = "app-language-\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: name)) }
        /// What the suite's own domain holds (`stringArray(forKey:)` falls back to the global domain).
        var languages: [String]? { defaults.persistentDomain(forName: name)?[AppLanguageApplier.languagesKey] as? [String] }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func aCodeIsWrittenAndPushedToThePages() throws {
        let suite = try Suite()
        var pushed: [String?] = []
        let applier = AppLanguageApplier(defaults: suite.defaults) { pushed.append($0) }
        applier.apply("ja")
        #expect(suite.languages == ["ja"])
        #expect(pushed == ["ja"])
    }

    @Test func systemRemovesCmuxsOwnWrite() throws {
        let suite = try Suite()
        var pushed: [String?] = []
        let applier = AppLanguageApplier(defaults: suite.defaults) { pushed.append($0) }
        applier.apply("de")
        applier.apply(nil)
        #expect(suite.languages == nil)
        #expect(suite.defaults.persistentDomain(forName: suite.name)?[AppLanguageApplier.appliedKey] == nil)
        #expect(pushed == ["de", nil])
    }

    @Test func systemKeepsAPerAppLanguageCmuxDidNotWrite() throws {
        let suite = try Suite()
        // macOS System Settings > Language & Region > Applications wrote French for cmux.
        suite.defaults.set(["fr"], forKey: AppLanguageApplier.languagesKey)
        AppLanguageApplier(defaults: suite.defaults) { _ in }.apply(nil)
        #expect(suite.languages == ["fr"])
    }

    @Test func aNewCodeReplacesTheLastOne() throws {
        let suite = try Suite()
        let applier = AppLanguageApplier(defaults: suite.defaults) { _ in }
        applier.apply("ko")
        applier.apply("zh-Hans")
        #expect(suite.languages == ["zh-Hans"])
        applier.apply(nil)
        #expect(suite.languages == nil)
    }

    @Test func thePageScriptHandsTheCodeOrNull() {
        #expect(PageWebView.languageScript("pt-BR") == #"window.__cmuxSetAppLanguage?.("pt-BR");"#)
        #expect(PageWebView.languageScript(nil) == "window.__cmuxSetAppLanguage?.(null);")
    }

    @Test func theRelaunchRowNeedsAClick() async throws {
        var relaunches = 0
        let route = AppLanguageRelaunchRoute { relaunches += 1 }
        let op = AppLanguageRelaunchRoute.prefix + "relaunch"
        await #expect(throws: PageError.self) {
            _ = try await route.call(op, params: .object([:]), context: PageCallContext(page: "cmux.settings"))
        }
        #expect(relaunches == 0)
        _ = try await route.call(op, params: .object([:]), context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(relaunches == 1)
    }
}
