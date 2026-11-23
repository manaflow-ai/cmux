import Foundation
import Testing
@testable import CmuxNextDaemon

/// A classic window opens where it was saved only when a screen now shows most of it.
struct ClassicWindowFrameTests {
    private static func window(_ frame: String?) throws -> ClassicMigrationPlan.Window {
        let json = #"{"workspaces": []"# + (frame.map { #", "frame": \#($0)"# } ?? "") + "}"
        return try JSONDecoder().decode(ClassicMigrationPlan.Window.self, from: Data(json.utf8))
    }

    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func aFrameOnAScreenIsKept() throws {
        let window = try Self.window(#"{"x": 100, "y": 100, "width": 800, "height": 600}"#)
        #expect(window.frame(onScreens: [Self.screen]) == CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    @Test func aFrameMostlyOffEveryScreenOpensAtTheDefaultPlace() throws {
        let window = try Self.window(#"{"x": 1300, "y": 100, "width": 800, "height": 600}"#)
        #expect(window.frame(onScreens: [Self.screen]) == nil)
        #expect(window.frame(onScreens: []) == nil)
    }

    @Test func aNarrowFrameNeedsAllOfItsWidthShown() throws {
        let window = try Self.window(#"{"x": 1300, "y": 100, "width": 140, "height": 300}"#)
        #expect(window.frame(onScreens: [Self.screen]) != nil)
        #expect(window.frame(onScreens: [CGRect(x: 0, y: 0, width: 1400, height: 900)]) == nil)
    }

    @Test func noSavedFrameIsNil() throws {
        #expect(try Self.window(nil).frame(onScreens: [Self.screen]) == nil)
    }
}
