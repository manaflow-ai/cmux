import CoreGraphics
import Testing

/// The window-session condition excludes sheet tests on a headless worker
/// and keeps them in the GUI lane.
struct WindowSessionTests {
    @Test func noSessionOrABackgroundSessionIsHeadless() {
        #expect(!WindowSession.isWindowSession(nil))
        #expect(!WindowSession.isWindowSession([:]))
        #expect(!WindowSession.isWindowSession([kCGSessionOnConsoleKey: false]))
    }

    @Test func aConsoleSessionIsAWindowSession() {
        #expect(WindowSession.isWindowSession([kCGSessionOnConsoleKey: true, kCGSessionUserNameKey: "cmux"]))
    }
}
