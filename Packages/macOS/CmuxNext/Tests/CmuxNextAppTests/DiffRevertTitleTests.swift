@testable import CmuxNextDiff
import Foundation
import Testing

/// The Revert sheet's title for several files picks the catalog's plural form for the file count.
@MainActor
struct DiffRevertTitleTests {
    static func title(_ files: Int, _ language: String) -> String {
        DiffPageStrings.revertManyTitle(files, preferredLocalizations: [language], locale: Locale(identifier: "en_US@numbers=latn"))
    }

    @Test func english() {
        #expect(Self.title(2, "en") == "Revert changes to 2 files?")
        #expect(Self.title(9, "en") == "Revert changes to 9 files?")
    }

    @Test(arguments: [(2, "2 ملفين؟"), (3, "3 ملفات؟"), (11, "11 ملفًا؟"), (100, "100 ملف؟")])
    func arabicAgreesWithTheCount(files: Int, ending: String) {
        #expect(Self.title(files, "ar") == "هل تريد التراجع عن التغييرات في " + ending)
    }

    @Test func bosnianAgreesWithTheCount() {
        #expect(Self.title(2, "bs") == "Vratiti izmjene u 2 datoteke?")
        #expect(Self.title(5, "bs") == "Vratiti izmjene u 5 datoteka?")
    }
}
