@testable import CmuxNextApp
import CmuxNextAccounts
import CmuxNextFilesUI
import CmuxNextLayout
import CmuxNextTasks
import Foundation
import Testing

/// A string table resolves from the bundle of the module whose strings type looks it up.
///
/// B1 (ba5e6df99f9) moved BrowserImportOffer.xcstrings to CmuxNextOnboarding while
/// BrowserImportOfferStrings stayed in the App, so the offer showed English in every locale; it
/// put Billing.xcstrings in CmuxNextAccounts with no resource rule. B1 also moved FileExplorer,
/// Screens and WorkspaceChecklist. Each case reads the Japanese text of one key from the strings
/// type's own bundle and expects a translation, not English. A table moved away from its strings
/// type gets a case here in the same change.
@Suite struct MovedStringTablesTests {
    enum Table: String, CaseIterable, Sendable {
        case browserImportOffer = "BrowserImportOffer"
        case billing = "Billing"
        case fileExplorer = "FileExplorer"
        case screens = "Screens"
        case workspaceChecklist = "WorkspaceChecklist"

        var bundle: Bundle {
            switch self {
            case .browserImportOffer: BrowserImportOfferStrings.bundle
            case .billing: BillingStrings.bundle
            case .fileExplorer: FileExplorerStrings.bundle
            case .screens: ScreenStrings.bundle
            case .workspaceChecklist: WorkspaceChecklistStrings.bundle
            }
        }

        /// One key of the table and its English text.
        var sample: (key: String, english: String) {
            switch self {
            case .browserImportOffer: ("browserImportOffer.notNow", "Not Now")
            case .billing: ("billing.error.notSignedIn", "Sign in to cmux in the cmux app first.")
            case .fileExplorer: ("fileExplorer.noFolder", "No folder")
            case .screens: ("screens.bar.accessibility", "Screens")
            case .workspaceChecklist: ("workspaceChecklist.page.addPlaceholder", "Add an item")
            }
        }
    }

    @Test(arguments: Table.allCases)
    func japaneseResolvesFromTheStringsTypesBundle(table: Table) throws {
        let bundle = table.bundle
        let japanese = try #require(bundle.url(forResource: "ja", withExtension: "lproj").flatMap(Bundle.init(url:)),
                                    "\(bundle.bundlePath) has no ja.lproj")
        let missing = "\u{0}missing"
        let text = japanese.localizedString(forKey: table.sample.key, value: missing, table: table.rawValue)
        #expect(text != missing, "\(table.rawValue).\(table.sample.key) is not in \(bundle.bundlePath)")
        #expect(text != table.sample.english)
        #expect(!text.isEmpty)
    }
}
