import AppKit
import class CmuxNextAgentPane.AgentPaneStateFiles
import class CmuxNextDesign.LaunchReveal
@testable import CmuxNextApp

extension AppServices {
    /// The services a test builds. The sources read the application object only if the test made one
    /// (`NSApplication.shared`; a GUI-lane test can have a real key window), and never unwrap the global:
    /// with none, there is no key window and the app is not active. Only the test target has this
    /// initializer, so the app's composition root (`AppDelegate`) must pass both sources.
    /// `heldKeyReplay`: the app's own (`NSApp.sendEvent`) unless a test of the creation hold passes its window's.
    /// `agentPaneStateFiles`: the agent panes' state files the services own (a quit test holds one's queue).
    convenience init(environment: AppEnvironment, launchReveal: LaunchReveal = .shared, agentPaneEnvironment: [String: String]? = nil,
                     heldKeyReplay: @escaping HeldKeyReplay = { event, _, _ in NSApp?.sendEvent(event) },
                     agentPaneStateFiles: AgentPaneStateFiles = AgentPaneStateFiles()) {
        self.init(environment: environment, keyWindowSource: { NSApp?.keyWindow }, appActiveSource: { NSApp?.isActive ?? false },
                  heldKeyReplay: heldKeyReplay, launchReveal: launchReveal, agentPaneEnvironment: agentPaneEnvironment,
                  agentPaneStateFiles: agentPaneStateFiles)
    }
}
