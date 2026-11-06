import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The app builds ``UIInspectorController`` with its services, before Debug Settings activates the
/// tunables (`AppDelegate`: `services.debugSettings.start()`). A watch of `agent.pointerInspector`
/// armed then registered no Observation dependency, so turning the setting off left a running
/// picker and its event monitor on (router review of #36058, F1). Reproduces only while nothing
/// in the process activated the store first: run this suite on its own.
@MainActor @Suite(.serialized) struct InspectElementToggleOffAfterLaunchTests {
    @Test func turningTheInspectorOffStopsAPickerStartedAfterLaunch() async {
        let launchOrder = !TunableStore.shared.isActive
        let services = AppServices(environment: AppEnvironment.current([:]))
        let inspector = services.uiInspector
        // What DebugSettingsService.start() does after the services are built.
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(true))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }

        inspector.toggle()
        #expect(inspector.isPicking)
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(false))
        let deadline = ContinuousClock.now + .seconds(2)
        while inspector.isPicking, ContinuousClock.now < deadline { await Task.yield() }

        #expect(!inspector.isPicking, "the picker kept running after the inspector was turned off (launch order: \(launchOrder))")
        if inspector.isPicking {
            TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(true))
            inspector.toggle()
        }
    }
}
