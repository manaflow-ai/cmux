import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings
import Foundation
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
        #expect(page.gestureActions == ["remote.newGroup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording"])
        #expect(page.personBackedActions == ["palette.computerUse.accessibility", "palette.computerUse.screenRecording"])
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

    /// Settings' Grant Access (the Computer Use card) on the person's fresh click reaches the native
    /// provider as their own run, so the grant handler's `byPerson` (``ActionInvocation/isPersonsOwnRun``)
    /// starts that grant's Allow in the guided window at once; page script alone, or a spent click, only
    /// opens the window (no second click needed, none faked).
    @Test func aFreshSettingsGrantClickStartsTheAllowAsThePerson() async throws {
        let page = PageDescriptor.settings
        for action in ["palette.computerUse.accessibility", "palette.computerUse.screenRecording"] {
            #expect(page.actions.contains(action) && page.gestureActions.contains(action), "\(action)")
            let recorder = Recorder()
            let provider = PageGestureActionProvider(page: page, wrapping: recorder, backs: { $0 == 7_001 })
            let run: JSONValue = ["action": .string(action)]
            let click = PageCallContext(page: page.id, userGesture: true, gestureEvent: 7_001)
            _ = try await provider.call(PageNativeOp.actionRun, params: run, context: PageCallContext(page: page.id))
            _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
            _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
            #expect(recorder.contexts.map(\.isConfirmedUser) == [false, true, false], "\(action)")
            // AppPageNativeProvider's invocation for each: origin `user` for a confirmed user, else `page`.
            let byPerson = recorder.contexts.map { ActionInvocation(origin: $0.isConfirmedUser ? .user : .page, focusRequested: true).isPersonsOwnRun }
            #expect(byPerson == [false, true, false], "\(action)")
        }
        // Set Up and Restart start nothing by themselves: they stay page runs.
        #expect(!page.gestureActions.contains("palette.computerUse.setup"))
        #expect(!page.gestureActions.contains("palette.computerUse.restart"))
    }

    /// Final review of #48024 (P1): a click another process posts on Grant Access reaches WebKit as a real event, so the
    /// page gesture alone is no proof. A grant run whose gesture the HID ledger does not back (`backs`) is refused and
    /// never reaches the native provider, as the person's or as the page's; with no `backs` none is backed. Page script
    /// with no gesture still only opens the window (a page run), and the host picker keeps its gesture rule.
    @Test func aPostedGrantClickIsRefusedNotPromoted() async throws {
        let page = PageDescriptor.settings
        let unbacked: [(@MainActor (TimeInterval) -> Bool)?] = [{ _ in false }, nil]
        for backs in unbacked {
            for action in ["palette.computerUse.accessibility", "palette.computerUse.screenRecording"] {
                let recorder = Recorder()
                let provider = PageGestureActionProvider(page: page, wrapping: recorder, backs: backs, refusal: "person only")
                let run: JSONValue = ["action": .string(action)]
                let posted = PageCallContext(page: page.id, userGesture: true, gestureEvent: 6_001)
                await #expect(throws: PageError.self, "\(action)") { try await provider.call(PageNativeOp.actionRun, params: run, context: posted) }
                do {
                    _ = try await provider.call(PageNativeOp.actionRun, params: run, context: posted)
                } catch let error as PageError {
                    #expect(error.code == PageNativeOp.userOnlyCode && error.message == "person only")
                }
                #expect(recorder.contexts.isEmpty, "\(action): an unbacked click reached the native provider")
                #expect(!provider.runsAsPerson(action, posted), "\(action)")
                _ = try await provider.call(PageNativeOp.actionRun, params: run, context: PageCallContext(page: page.id))
                #expect(recorder.contexts.map(\.isConfirmedUser) == [false], "\(action): page script did not stay a page run")
            }
            // The host picker needs no HID backing: a fresh click still opens it as the person.
            let recorder = Recorder()
            let provider = PageGestureActionProvider(page: page, wrapping: recorder, backs: backs)
            _ = try await provider.call(PageNativeOp.actionRun, params: ["action": "remote.newGroup"],
                                        context: PageCallContext(page: page.id, userGesture: true, gestureEvent: 6_002))
            #expect(recorder.contexts.map(\.isConfirmedUser) == [true])
        }
    }

    /// The App Store's Open is the person's own `app.open` on a fresh click, so a widget app's Open
    /// gets their Cmd-T New Tab page; a page script's run stays `page` (a real build opened nothing).
    @Test func onlyAFreshAppStoreClickOpensAnAppAsThePerson() async throws {
        let page = PageDescriptor.apps
        #expect(page.gestureActions == ["app.open"])
        let recorder = Recorder()
        let provider = PageGestureActionProvider(page: page, wrapping: recorder)
        let run: JSONValue = ["action": "app.open", "args": ["app": "cmux/clock"]]
        let click = PageCallContext(page: page.id, userGesture: true, gestureEvent: 9_001)
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: PageCallContext(page: page.id))
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        _ = try await provider.call(PageNativeOp.actionRun, params: run, context: click)
        #expect(recorder.contexts.map(\.isConfirmedUser) == [false, true, false])
    }
}
