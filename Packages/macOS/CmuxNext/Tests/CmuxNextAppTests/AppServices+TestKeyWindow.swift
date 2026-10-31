import AppKit
import class CmuxNextDesign.LaunchReveal
@testable import CmuxNextApp

extension AppServices {
    /// The services a test builds. The sources read the application object only if the test made one
    /// (`NSApplication.shared`; a GUI-lane test can have a real key window), and never unwrap the global:
    /// with none, there is no key window and the app is not active. Only the test target has this
    /// initializer, so the app's composition root (`AppDelegate`) must pass both sources.
    convenience init(environment: AppEnvironment, launchReveal: LaunchReveal = .shared, agentPaneEnvironment: [String: String]? = nil) {
        self.init(environment: environment, keyWindowSource: { NSApp?.keyWindow }, appActiveSource: { NSApp?.isActive ?? false },
                  launchReveal: launchReveal, agentPaneEnvironment: agentPaneEnvironment)
    }
}
