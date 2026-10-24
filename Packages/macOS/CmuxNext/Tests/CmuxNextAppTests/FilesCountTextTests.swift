@testable import CmuxNextFilesUI
import Foundation
import Testing

/// The Files pane's counts agree with the number in every language: a plural form per count, a label before the
/// count where a form cannot carry it, and byte counts written by Foundation in the sentence's language.
@MainActor
struct FilesCountTextTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    @Test func theStatusBarCountsItems() {
        let items = { (count: Int, language: String) in FilesStrings.items(count, preferredLocalizations: [language], locale: Self.latin) }
        #expect(items(1, "en") == "1 item")
        #expect(items(5, "en") == "5 items")
        #expect(items(1, "de") == "1 Objekt")
        #expect(items(1, "ar") == "عنصر واحد (1)")
        #expect(items(2, "ar") == "عنصران (2)")
        #expect(items(3, "ar") == "3 عناصر")
        #expect(items(11, "ar") == "11 عنصرًا")
        #expect(FilesStrings.copying(1, preferredLocalizations: ["en"], locale: Self.latin) == "Copying 1 item…")
        #expect(FilesStrings.copying(3, preferredLocalizations: ["ar"], locale: Self.latin) == "جارٍ نسخ 3 عناصر…")
    }

    @Test func promptsNameTheItemsInTheCountsForm() {
        #expect(FilesStrings.renameItemsTitle(2, preferredLocalizations: ["en"], locale: Self.latin) == "Rename 2 Items")
        #expect(FilesStrings.renameItemsTitle(3, preferredLocalizations: ["ar"], locale: Self.latin) == "إعادة تسمية 3 عناصر")
        #expect(FilesStrings.deleteConfirm(1, preferredLocalizations: ["en"], locale: Self.latin)
            == "Are you sure you want to delete this 1 item immediately?")
        #expect(FilesStrings.deleteConfirm(4, preferredLocalizations: ["en"], locale: Self.latin)
            == "Are you sure you want to delete these 4 items immediately?")
        #expect(FilesStrings.deleteConfirm(1, preferredLocalizations: ["ru"], locale: Self.latin) == "Удалить этот объект (1) немедленно?")
    }

    @Test func getInfoWritesSizesWithFoundationsUnits() {
        #expect(FilesStrings.infoFolderSize("1.2 MB", 1, preferredLocalizations: ["en"], locale: Self.latin) == "1.2 MB (items: 1)")
        #expect(FilesStrings.infoBytes("2 KB", 2048, preferredLocalizations: ["en"], locale: Self.latin) == "2 KB (2,048 bytes)")
        // Polish takes a different noun for 2 than for 5; Foundation writes the right one.
        let polish = FilesStrings.infoBytes("2 B", 2, preferredLocalizations: ["pl"], locale: Self.latin)
        let bytes = Int64(2).formatted(.byteCount(style: .file, allowedUnits: .bytes, spellsOutZero: false)
            .locale(Locale(identifier: "pl_US@numbers=latn")))
        #expect(polish == "2 B (\(bytes))")
        #expect(!polish.contains("bajtów"), "\(polish)")
    }
}
