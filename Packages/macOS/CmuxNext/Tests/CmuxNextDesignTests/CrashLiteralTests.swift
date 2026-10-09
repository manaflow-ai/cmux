import Foundation
import Testing
@testable import CmuxNextDesign

/// Crash program: every backdrop's museum page is a literal that must parse.
@MainActor @Suite struct DesignCrashLiteralTests {
    @Test func everyBackdropSourceParses() {
        for art in BackdropArt.allCases {
            #expect(art.sourceURL.host == "www.metmuseum.org", "\(art)")
        }
    }
}
