@testable import CmuxNextApp
import Foundation
import Testing

/// History's count sentences pick the catalog's plural form for the count, in every language: the retention
/// setting accepts 1...3650 days, and an Undo can close one pane or many. The language is pinned
/// (preferredLocalizations) and the digits are Latin, so the host's own language does not matter.
@MainActor
struct CommandHistoryDeletePromptTests {
    static let latin = Locale(identifier: "en_US@numbers=latn")

    static func body(_ days: Int, _ language: String) -> String {
        HistoryAppStrings.deleteCommandsBody(days, preferredLocalizations: [language], locale: latin)
    }

    @Test func englishIsSingularForOneDay() {
        let prefix = "Recording is off. Each connected machine keeps the commands it already recorded until they are "
        #expect(Self.body(1, "en") == prefix + "1 day old.")
        #expect(Self.body(30, "en") == prefix + "30 days old.")
    }

    /// Arabic has a form for 1, 2, 3 to 10, 11 to 99 and 100 and more.
    @Test(arguments: [(1, "1 يوم."), (2, "2 يومين."), (3, "3 أيام."), (11, "11 يومًا."), (100, "100 يوم.")])
    func arabicAgreesWithTheCount(days: Int, ending: String) {
        #expect(Self.body(days, "ar") == "التسجيل متوقف. يحتفظ كل جهاز متصل بالأوامر التي سجّلها بالفعل حتى يصبح عمرها " + ending)
    }

    @Test(arguments: [(1, "1 dzień."), (2, "2 dni."), (5, "5 dni.")])
    func polishAgreesWithTheCount(days: Int, ending: String) {
        #expect(Self.body(days, "pl")
            == "Zapisywanie jest wyłączone. Każda połączona maszyna przechowuje już zapisane polecenia, dopóki nie będą miały " + ending)
    }

    @Test(arguments: [(1, "1 dan."), (2, "2 dana."), (5, "5 dana.")])
    func bosnianAgreesWithTheCount(days: Int, ending: String) {
        #expect(Self.body(days, "bs") == "Snimanje je isključeno. Svaka povezana mašina čuva već snimljene komande dok ne postanu stare " + ending)
    }

    @Test func anUndoThatClosesPanesNamesThemInTheCountsForm() {
        let undo = { (count: Int, language: String) in
            HistoryAppStrings.undoClosesPanes(count, preferredLocalizations: [language], locale: Self.latin)
        }
        #expect(undo(1, "en") == "Undo closes 1 pane. Run Undo Layout Change again to confirm.")
        #expect(undo(3, "en") == "Undo closes 3 panes. Run Undo Layout Change again to confirm.")
        #expect(undo(3, "ar") == "التراجع يغلق 3 أجزاء. شغّل التراجع عن تغيير التخطيط مرة أخرى للتأكيد.")
        #expect(undo(11, "ar") == "التراجع يغلق 11 جزءًا. شغّل التراجع عن تغيير التخطيط مرة أخرى للتأكيد.")
        #expect(undo(2, "bs") == "Poništavanje zatvara 2 okna. Ponovo pokrenite Poništi promjenu rasporeda za potvrdu.")
    }
}
