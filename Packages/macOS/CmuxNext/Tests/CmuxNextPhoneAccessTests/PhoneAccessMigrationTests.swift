@testable import CmuxNextPhoneAccess
import Testing

/// Phone access became opt-in. A Mac whose phone host already ran keeps
/// serving phones, once; a person's own choice and a second launch never
/// change anything.
struct PhoneAccessMigrationTests {
    @Test func aMacThatServedPhonesKeepsThem() {
        #expect(PhoneAccessMigration.decide(alreadyRan: false, chosen: false, servedPhones: true) == true)
    }

    @Test func aFreshMacStaysOff() {
        #expect(PhoneAccessMigration.decide(alreadyRan: false, chosen: false, servedPhones: false) == nil)
    }

    @Test func thePersonsChoiceWins() {
        #expect(PhoneAccessMigration.decide(alreadyRan: false, chosen: true, servedPhones: true) == nil)
    }

    @Test func itRunsOnce() {
        #expect(PhoneAccessMigration.decide(alreadyRan: true, chosen: false, servedPhones: true) == nil)
    }
}
