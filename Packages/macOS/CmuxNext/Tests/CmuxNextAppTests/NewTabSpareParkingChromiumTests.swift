import AppKit
import CmuxNextPages
@testable import CmuxNextApp
import Testing

/// The New Tab spare's parking is off-screen parking, so a Chromium spare paints there before Cmd-T adopts it.
@MainActor
struct NewTabSpareParkingChromiumTests {
    @Test func theSpareParkingLetsAChromiumSpareDraw() {
        let parking: NSView = NewTabSpareParking(frame: .zero)
        #expect(parking.alphaValue == 0)
        #expect(parking is any PageChromiumOffscreenParking)
    }
}
