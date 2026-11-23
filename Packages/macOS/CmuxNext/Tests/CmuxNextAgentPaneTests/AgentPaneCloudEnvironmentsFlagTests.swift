import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `CLOUD_ENVIRONMENTS_ENABLED` (the composer's Cloud Environment chip): on unless the bundle's
/// `LSEnvironment` or the launch environment says `0` or `false`; the bundle's value wins.
struct AgentPaneCloudEnvironmentsFlagTests {
    @Test func onUnlessSet() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: [:]).enabled)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: [:], environment: [:]).enabled)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "1"]).enabled)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "yes"]).enabled)
    }

    @Test func offWhenTheLaunchEnvironmentSaysSo() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: nil, environment: ["CLOUD_ENVIRONMENTS_ENABLED": "0"]).enabled == false)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: [:], environment: ["CLOUD_ENVIRONMENTS_ENABLED": " FALSE "]).enabled == false)
    }

    @Test func theBundleWins() {
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: ["CLOUD_ENVIRONMENTS_ENABLED": "0"],
                                               environment: ["CLOUD_ENVIRONMENTS_ENABLED": "1"]).enabled == false)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: ["CLOUD_ENVIRONMENTS_ENABLED": "1"],
                                               environment: ["CLOUD_ENVIRONMENTS_ENABLED": "false"]).enabled)
        #expect(AgentPaneCloudEnvironmentsFlag(bundled: ["CLOUD_ENVIRONMENTS_ENABLED": "false"], environment: [:]).enabled == false)
    }

    /// The page reads it as the `composer` event's `cloudEnvironments` (composerSettings.ts).
    @Test func theComposerEventCarriesIt() {
        let value = AgentPaneComposerSetting().pageValueWithLook.objectValue
        #expect(value?["cloudEnvironments"]?.boolValue == AgentPaneCloudEnvironmentsFlag.current.enabled)
    }
}
