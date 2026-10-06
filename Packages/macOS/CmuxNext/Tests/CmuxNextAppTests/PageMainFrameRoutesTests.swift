import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp

/// The app's own pages route by fragment only, so the page host's main-frame rule (only the
/// entry document) keeps their first load and every route change (PageMainFrameTests covers the
/// shared pages).
@MainActor
@Suite struct PageMainFrameRoutesTests {
    /// Main-actor statics: read inside the test, not in `@Test(arguments:)` (Xcode 27 refuses that).
    @Test func everyAppPageRoutesByFragmentOnly() {
        for descriptor in [PageDescriptor.passwords, .iconPicker, .keybindings] {
            func policy(_ url: URL?) -> PageNavigation.Policy {
                PageNavigation.policy(for: url, page: descriptor, userClicked: false, mainFrame: true, hook: nil)
            }
            #expect(policy(descriptor.url()) == .allow, "\(descriptor.id)")
            #expect(policy(descriptor.url(route: "#/x")) == .allow, "\(descriptor.id)")
            #expect(policy(descriptor.url().appendingPathComponent("other")) == .cancel, "\(descriptor.id)")
        }
    }
}
