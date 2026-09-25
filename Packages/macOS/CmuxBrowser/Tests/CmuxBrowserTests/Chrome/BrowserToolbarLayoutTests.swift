import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct BrowserToolbarLayoutTests {
    private let jsonFormatter = BrowserToolbarItem.pinnedExtension("bcjindcccaagfpapjjmafapmmgkkhgoa")

    @Test func missingValueIsDefaultAndEmptyValueHidesEverything() {
        #expect(BrowserToolbarLayout(storedValue: nil) == .default)
        #expect(BrowserToolbarLayout(storedValue: "").items.isEmpty)
    }

    @Test func roundTripsThroughStorageAndDropsUnknownOrMalformedValues() {
        let layout = BrowserToolbarLayout(storedValue: "theme\nextension:bcjindcccaagfpapjjmafapmmgkkhgoa\nbogus\nextension:../../x\ntheme\nprofile")
        #expect(layout.items == [.theme, jsonFormatter, .profile])
        #expect(BrowserToolbarLayout(storedValue: layout.storedValue) == layout)
    }

    @Test func showingABuiltInRestoresItsDefaultPosition() {
        var layout = BrowserToolbarLayout.default
        layout.hide(.theme)
        layout.show(.theme)
        #expect(layout == .default)
    }

    @Test func pinningPlacesExtensionsAfterTheExtensionsButtonInPinOrder() {
        var layout = BrowserToolbarLayout.default
        let second = BrowserToolbarItem.pinnedExtension("nngceckbapebfimnlniiiahkandclblb")
        layout.show(jsonFormatter)
        layout.show(second)
        #expect(layout.items == [.designMode, .profile, .theme, .extensions, jsonFormatter, second, .devTools])
    }

    @Test func movesLeftAndRightWithinBounds() {
        var layout = BrowserToolbarLayout.default
        #expect(!layout.canMove(.designMode, by: -1))
        layout.move(.designMode, by: 1)
        #expect(layout.items.prefix(2) == [.profile, .designMode])
        layout.move(.devTools, by: 1)
        #expect(layout.items.last == .devTools)
    }

    @Test func dragReorderMatchesOnMoveSemantics() {
        var layout = BrowserToolbarLayout.default
        layout.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(layout.items == [.devTools, .designMode, .profile, .theme, .extensions])
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 5)
        #expect(layout == .default)
    }

    @Test func removesPinsForUninstalledExtensions() {
        var layout = BrowserToolbarLayout.default
        layout.show(jsonFormatter)
        layout.removePinned(notIn: [])
        #expect(layout == .default)
    }

    @Test func savingTheDefaultRemovesTheStoredValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserToolbarLayoutTests-\(UUID().uuidString)"))
        var layout = BrowserToolbarLayout.default
        layout.hide(.devTools)
        layout.save(to: defaults)
        #expect(BrowserToolbarLayout.load(from: defaults) == layout)
        BrowserToolbarLayout.default.save(to: defaults)
        #expect(defaults.object(forKey: BrowserToolbarLayout.userDefaultsKey) == nil)
    }
}
