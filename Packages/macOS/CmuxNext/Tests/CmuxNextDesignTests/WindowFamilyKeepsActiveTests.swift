@testable import CmuxNextDesign
import Testing

/// Leo, 2026-10-21: "really really dislike when i move to a browser-tab workspace that it unfocuses
/// the app and the whole glass ... becomes less glassy. Against other apps, ok sure, but on
/// itself? that should never happen." The keyboard moving into cmux's own Chromium page window,
/// popup, palette or sheet keeps the window's active look; only another app (or another window)
/// taking the keyboard makes it look inactive.
@Suite struct WindowFamilyKeepsActiveTests {
    final class Window {
        let parent: Window?
        init(parent: Window? = nil) { self.parent = parent }
    }

    static func holds(_ window: Window, _ key: Window?) -> Bool {
        WindowMaterialView.family(of: window, holds: key, owner: { $0.parent })
    }

    @Test func itsOwnPageWindowPopupOrSheetIsTheFamily() {
        let shell = Window()
        let page = Window(parent: shell)
        let popupOverPage = Window(parent: page)
        #expect(Self.holds(shell, shell))
        #expect(Self.holds(shell, page))
        #expect(Self.holds(shell, popupOverPage))
    }

    @Test func anotherWindowOrNoKeyWindowIsNot() {
        let shell = Window()
        let other = Window()
        #expect(!Self.holds(shell, other))
        #expect(!Self.holds(shell, Window(parent: other)))
        #expect(!Self.holds(shell, nil))
    }

    @Test func aBrowserPageTakingTheKeyboardKeepsTheActiveLook() {
        // The page window is key: the family holds it.
        #expect(!WindowMaterialView.looksInactive(appActive: true, familyHoldsKey: true, familyHeldKey: true))
    }

    @Test func anotherAppOrAnotherWindowMakesItLookInactive() {
        #expect(WindowMaterialView.looksInactive(appActive: false, familyHoldsKey: false, familyHeldKey: true))
        #expect(WindowMaterialView.looksInactive(appActive: false, familyHoldsKey: true, familyHeldKey: true))
        #expect(WindowMaterialView.looksInactive(appActive: true, familyHoldsKey: false, familyHeldKey: true))
    }

    @Test func aWindowWhoseFamilyNeverHeldTheKeyboardShowsTheGlassAlone() {
        #expect(!WindowMaterialView.looksInactive(appActive: false, familyHoldsKey: false, familyHeldKey: false))
        #expect(!WindowMaterialView.looksInactive(appActive: true, familyHoldsKey: false, familyHeldKey: false))
    }
}
