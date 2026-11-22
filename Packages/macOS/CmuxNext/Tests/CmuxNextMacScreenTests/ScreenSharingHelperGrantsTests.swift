import CoreGraphics
import Foundation
@testable import CmuxNextComputerUse
import Testing

/// The app's grant holder is the Screen Sharing helper: its requests are the helper's hidden modes
/// (cmux-tui/crates/cmux-rd-host/src/grant_requests.rs), and a build without the helper does nothing.
struct ScreenSharingHelperGrantsTests {
    @Test func aKeyPressCarriesOnlyTheFourModifiers() {
        // Option-Space with Caps Lock and the Fn bit held: the helper refuses anything but a chord.
        let flags: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskSecondaryFn]
        #expect(ScreenSharingHelperGrants.postKeyArguments(49, flags: flags) == ["__post-key", "49", "524288"])
        #expect(ScreenSharingHelperGrants.postKeyArguments(2, flags: [.maskControl, .maskAlternate]) == ["__post-key", "2", "786432"])
    }

    @Test func theHelpersLineSaysWhetherItHeldTheGrant() throws {
        let decode = { (line: String) in try JSONDecoder().decode(ScreenSharingHelperGrants.Answer.self, from: Data(line.utf8)) }
        #expect(ScreenSharingHelperGrants.result(try decode(#"{"granted":true}"#)) == .done)
        #expect(ScreenSharingHelperGrants.result(try decode(#"{"granted":false}"#)) == .notGranted)
        #expect(ScreenSharingHelperGrants.result(nil) == .unavailable)
        #expect(try decode(#"{"granted":true,"width":1440,"height":900}"#) == .init(granted: true, width: 1440, height: 900))
    }

    @Test func aStillIsTheHelpersPackedPixels() throws {
        let image = try #require(GrantHolderPixels(width: 3, height: 2, rgba: Data(repeating: 255, count: 4 * 3 * 2)).image)
        #expect(image.width == 3 && image.height == 2)
        // A short file is no picture.
        #expect(GrantHolderPixels(width: 3, height: 2, rgba: Data(count: 5)).image == nil)
    }

    @Test func withoutTheHelperNothingRuns() async {
        let grants = ScreenSharingHelperGrants(lookup: { nil }, launch: .screenSharing(bundleID: "com.cmuxterm.test"))
        #expect(await grants.postKey(49, flags: .maskAlternate) == .unavailable)
        #expect(await grants.screenStill(maxWidth: 1440, excluding: getpid()) == .unavailable)
    }
}
