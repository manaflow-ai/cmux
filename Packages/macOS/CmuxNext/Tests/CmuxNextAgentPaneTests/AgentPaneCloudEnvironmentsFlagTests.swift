import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `CLOUD_ENVIRONMENTS_ENABLED` (the composer's Cloud Environment chip): off unless the bundle's
/// `LSEnvironment` or the launch environment says `1` or `true`; the bundle's value wins.
struct AgentPaneCloudEnvironmentsFlagTests {
    @Test func offUnlessSet() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: [:]).enabled == false)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: [:], environment: ["CLOUD_ENVIRONMENTS_ENABLED": "0"]).enabled == false)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "yes"]).enabled == false)
    }

    @Test func onWhenTheLaunchEnvironmentSaysSo() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "1"]).enabled)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "TRUE"]).enabled)
    }

    @Test func theBundleWins() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: ["CLOUD_ENVIRONMENTS_ENABLED": "0"],
                                               environment: ["CLOUD_ENVIRONMENTS_ENABLED": "1"]).enabled == false)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: ["CLOUD_ENVIRONMENTS_ENABLED": "1"], environment: [:]).enabled)
    }

    /// The page reads it as the `composer` event's `cloudEnvironments` (composerSettings.ts).
    @Test func theComposerEventCarriesIt() {
        let value = AgentPaneComposerSetting().pageValueWithLook.objectValue
        #expect(value?["cloudEnvironments"]?.boolValue == AgentPaneCloudEnvironmentsFlag.current.enabled)
    }
}
