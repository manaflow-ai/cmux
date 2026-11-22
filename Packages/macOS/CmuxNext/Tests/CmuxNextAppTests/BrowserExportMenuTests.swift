@testable import CmuxNextApp
import CmuxNextBrowserImport
import Foundation
import Testing

/// Import from Another Browser…'s browser menu (Lawrence 2026-11-05: "auto detect browser",
/// "import from helium as well"): the browsers on this Mac come first and the default
/// browser is chosen, from Launch Services only (no browser data is read).
@Suite struct BrowserExportMenuTests {
    private func row(_ id: String, _ bundleID: String) -> BrowserExportSource {
        BrowserExportSource(id: id, name: id, family: .chromium, bundleIDs: [bundleID],
                            passwords: nil, bookmarks: nil, history: nil)
    }

    private var rows: [BrowserExportSource] {
        [row("chrome", "com.google.Chrome"), row("edge", "com.microsoft.edgemac"),
         row("helium", "net.imput.helium"), row("arc", "company.thebrowser.Browser")]
    }

    @Test func installedBrowsersComeFirstAndTheDefaultIsChosen() {
        let installed: Set = ["net.imput.helium", "company.thebrowser.Browser"]
        let menu = BrowserExportMenu(rows: rows, isInstalled: { installed.contains($0) },
                                     defaultBrowserBundleID: "company.thebrowser.Browser")
        #expect(menu.rows.map(\.id) == ["helium", "arc", "chrome", "edge"])
        #expect(menu.selected?.id == "arc")
    }

    @Test func aDefaultBrowserThatIsNotARowChoosesTheFirstInstalled() {
        // cmux itself (or any browser without export steps) as the default web browser.
        let menu = BrowserExportMenu(rows: rows, isInstalled: { $0 == "net.imput.helium" },
                                     defaultBrowserBundleID: "com.cmuxterm.app.nightly")
        #expect(menu.selected?.id == "helium")
    }

    @Test func nothingInstalledKeepsTheFileOrder() {
        let menu = BrowserExportMenu(rows: rows, isInstalled: { _ in false }, defaultBrowserBundleID: nil)
        #expect(menu.rows.map(\.id) == ["chrome", "edge", "helium", "arc"])
        #expect(menu.selected?.id == "chrome")
    }

    @Test func theBundledRowsOfferHeliumWithItsExportPages() throws {
        let helium = try #require(BrowserFileImport.exportRows().first { $0.id == "helium" })
        #expect(helium.name == "Helium")
        #expect(helium.family == .chromium)
        #expect(helium.bundleIDs == ["net.imput.helium"])
        #expect(helium.passwords == "chrome://password-manager/settings")
        #expect(helium.bookmarks == "chrome://bookmarks")
    }

    @Test func everyBundledBrowserRowCanBeDetected() {
        // Password managers too: 1Password and Bitwarden are apps Launch Services finds.
        for source in BrowserFileImport.exportRows() {
            #expect(!source.bundleIDs.isEmpty, "\(source.id) has no bundle id to detect it by")
        }
    }
}
