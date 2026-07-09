import AppKit
import Testing

@testable import CmuxWindowing

@MainActor
@Suite("DisplayGeometryReader")
struct DisplayGeometryReaderTests {
    @Test("available geometries mirror NSScreen.screens in order")
    func availableMirrorsScreens() {
        let reader = DisplayGeometryReader()
        let result = reader.currentDisplayGeometries()
        let screens = NSScreen.screens
        #expect(result.available.count == screens.count)
        for (geometry, screen) in zip(result.available, screens) {
            #expect(geometry.displayID == screen.cmuxDisplayID)
            #expect(geometry.frame == screen.frame)
            #expect(geometry.visibleFrame == screen.visibleFrame)
        }
    }

    @Test("fallback is the main screen, or the first when there is no main")
    func fallbackPrefersMain() {
        let reader = DisplayGeometryReader()
        let result = reader.currentDisplayGeometries()
        let expectedScreen = NSScreen.main ?? NSScreen.screens.first
        if let expectedScreen {
            #expect(result.fallback?.displayID == expectedScreen.cmuxDisplayID)
            #expect(result.fallback?.frame == expectedScreen.frame)
            #expect(result.fallback?.visibleFrame == expectedScreen.visibleFrame)
        } else {
            #expect(result.fallback == nil)
        }
    }

    @Test("a nil window resolves to no screen geometry")
    func nilWindowReturnsNil() {
        let reader = DisplayGeometryReader()
        #expect(reader.screenGeometry(for: nil) == nil)
    }
}
