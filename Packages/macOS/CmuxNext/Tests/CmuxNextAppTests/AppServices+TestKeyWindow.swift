import AppKit
import class CmuxNextDesign.LaunchReveal
@testable import CmuxNextApp

extension AppServices {
    /// The services a test builds: no key window (a window only becomes key in a running, active app).
    /// Only the test target has this initializer, so the app's composition root (`AppDelegate`) must
    /// pass its key-window source; a test that needs a key window sets `keyWindowSource` or passes one.
    convenience init(environment: AppEnvironment, launchReveal: LaunchReveal = .shared, agentPaneEnvironment: [String: String]? = nil) {
        self.init(environment: environment, keyWindowSource: { nil }, launchReveal: launchReveal, agentPaneEnvironment: agentPaneEnvironment)
    }
}
