import CmuxNextActions
import CmuxNextSidebar
import CmuxNextSidebarActions
import Testing

@MainActor struct SidebarScreenIntentActionsTests {
    @Test func dispatchPreservesDeviceIdentityAndRejectsUnavailableTargets() {
        let device = "a1111111-1111-4111-8111-111111111111"
        let sections: [SidebarSection] = [SidebarScreenActionTests.section("route", name: "Mac", kind: SidebarMachine.Kind.ssh, device: device),
                        SidebarScreenActionTests.section("offline", name: "Mac", kind: SidebarMachine.Kind.server, device: device, online: false),
                        SidebarScreenActionTests.section("linux", name: "Mac", kind: SidebarMachine.Kind.ssh),
                        SidebarScreenActionTests.section("cloud", name: "Cloud", kind: SidebarMachine.Kind.cloud)]
        var actions: [ActionID] = [], invocations: [ActionInvocation] = [], opened: [String] = []
        let handler = SidebarScreenIntentActions { actions.append($0); invocations.append($1) }
        for id in ["route", "offline", "linux", "missing", "cloud"] {
            handler.handle(.viewScreen(MachineID(id)), sections: sections) { opened.append($0) }
        }
        #expect(opened == [device], "only the authenticated online device UUID reaches the window's opener")
        #expect(actions == ["cloudOpenDesktop"])
        #expect(invocations.first?.target == ActionTargetRef(kind: .machine, id: "cloud"))
        #expect(invocations.first?.origin == .user)
        handler.handle(.shareScreen(MachineID("route")), sections: sections) { opened.append($0) }
        #expect(actions.count == 1, "a remote row cannot share this Mac")
        handler.handle(.shareScreen(.local), sections: sections) { opened.append($0) }
        #expect(actions == ["cloudOpenDesktop", "macScreen.shareThisMac"])
        #expect(invocations.last?.origin == .user)
        #expect(opened == [device])
    }
}
