import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser import value types")
struct BrowserImportValueTests {
    @Test("scope resolves from wizard checkbox selection")
    func scopeFromSelection() {
        #expect(BrowserImportScope.fromSelection(includeCookies: false, includeHistory: false, includeAdditionalData: false) == nil)
        #expect(BrowserImportScope.fromSelection(includeCookies: true, includeHistory: false, includeAdditionalData: false) == .cookiesOnly)
        #expect(BrowserImportScope.fromSelection(includeCookies: false, includeHistory: true, includeAdditionalData: false) == .historyOnly)
        #expect(BrowserImportScope.fromSelection(includeCookies: true, includeHistory: true, includeAdditionalData: false) == .cookiesAndHistory)
        #expect(BrowserImportScope.fromSelection(includeCookies: false, includeHistory: false, includeAdditionalData: true) == .everything)
    }

    @Test("scope includes-flags match expectations")
    func scopeIncludesFlags() {
        #expect(BrowserImportScope.cookiesOnly.includesCookies)
        #expect(!BrowserImportScope.cookiesOnly.includesHistory)
        #expect(BrowserImportScope.everything.includesCookies)
        #expect(BrowserImportScope.everything.includesHistory)
    }

    @Test("profile identity is the canonicalized path")
    func profileIdentity() {
        let a = InstalledBrowserProfile(displayName: "A", rootURL: URL(fileURLWithPath: "/tmp/x/"), isDefault: true)
        let b = InstalledBrowserProfile(displayName: "B", rootURL: URL(fileURLWithPath: "/tmp/x"), isDefault: false)
        #expect(a.id == b.id)
    }

    @Test("step-3 presentation reflects plan shape")
    func step3Presentation() {
        let single = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: [BrowserImportExecutionEntry(sourceProfiles: [], destination: .existing(UUID()))]
            )
        )
        #expect(!single.showsModeSelector)
        #expect(!single.showsSeparateRows)
        #expect(single.showsSingleDestinationPicker)

        let separate = BrowserImportStep3Presentation(
            plan: BrowserImportExecutionPlan(
                mode: .separateProfiles,
                entries: [
                    BrowserImportExecutionEntry(sourceProfiles: [], destination: .createNamed("A")),
                    BrowserImportExecutionEntry(sourceProfiles: [], destination: .createNamed("B")),
                ]
            )
        )
        #expect(separate.showsModeSelector)
        #expect(separate.showsSeparateRows)
        #expect(!separate.showsSingleDestinationPicker)
    }

    @Test("source-profiles presentation clamps the scroll height")
    func sourceProfilesPresentation() {
        let one = BrowserImportSourceProfilesPresentation(profileCount: 1)
        #expect(one.scrollHeight == 76)
        #expect(!one.showsHelpText)

        let many = BrowserImportSourceProfilesPresentation(profileCount: 9)
        #expect(many.scrollHeight == CGFloat(5 * 26 + 14))
        #expect(many.showsHelpText)
    }
}

@Suite("BrowserImportOutcome")
struct BrowserImportOutcomeTests {
    private func makeOutcome() -> BrowserImportOutcome {
        BrowserImportOutcome(
            browserName: "Google Chrome",
            scope: .cookiesAndHistory,
            domainFilters: ["example.com"],
            createdDestinationProfileNames: ["Work"],
            entries: [
                BrowserImportOutcomeEntry(
                    sourceProfileNames: ["Default"],
                    destinationProfileName: "Work",
                    importedCookies: 12,
                    skippedCookies: 3,
                    importedHistoryEntries: 40,
                    warnings: ["skipped some"]
                )
            ],
            warnings: ["skipped some"]
        )
    }

    @Test("totals aggregate across entries")
    func totals() {
        let outcome = makeOutcome()
        #expect(outcome.totalImportedCookies == 12)
        #expect(outcome.totalSkippedCookies == 3)
        #expect(outcome.totalImportedHistoryEntries == 40)
    }

    @Test("socket payload carries the wire keys")
    func socketPayload() {
        let payload = makeOutcome().socketPayload
        #expect(payload["browser"] as? String == "Google Chrome")
        #expect(payload["scope"] as? String == "cookiesAndHistory")
        #expect(payload["imported_cookies"] as? Int == 12)
        #expect((payload["entries"] as? [[String: Any]])?.count == 1)
    }

    @Test("formatted lines include browser, scope, cookies, history, and warnings")
    func formattedLines() {
        let lines = makeOutcome().formattedLines
        #expect(lines.contains { $0.contains("Google Chrome") })
        #expect(lines.contains { $0.contains("Imported cookies: 12") })
        #expect(lines.contains { $0.contains("Skipped cookies: 3") })
        #expect(lines.contains { $0.contains("Imported history entries: 40") })
        #expect(lines.contains { $0.hasPrefix("- skipped some") })
    }
}
