import CmuxNextPages
import CmuxNextSettings
import Testing

@MainActor
struct RemoteHostsSettingsEntryTests {
    private final class Recorder: PageProvider {
        var contexts: [PageCallContext] = []
        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            contexts.append(context)
            return ["ran": .bool(true)]
        }
    }

    @Test func settingsAdmitsTheExistingHostPicker() {
        let page = PageDescriptor.settings
        #expect(page.actions.contains("remote.newGroup"))
        #expect(page.gestureActions == ["remote.newGroup"])
        #expect(!page.actions.contains("remote.removeGroup"))
    }

    @Test func onlyAFreshSettingsGestureOpensThePickerAsThePerson() async throws {
        let page = PageDescriptor.settings
        let recorder = Recorder()
        let provider = PageGestureActionProvider(page: page, wrapping: recorder)
        let run: JSONValue = ["action": "remote.newGroup"]
        let click = PageCallContext(page: page.id, userGesture: true, gestureEvent: 8_001)
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: PageCallContext(page: page.id))
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        _ = try await provider.call(PageNativeOp.actionRun, params: run,
                                    context: PageCallContext(page: "cmux.other", userGesture: true, gestureEvent: 8_002))
        #expect(recorder.contexts.map(\.isConfirmedUser) == [false, true, false, false])
    }
}
