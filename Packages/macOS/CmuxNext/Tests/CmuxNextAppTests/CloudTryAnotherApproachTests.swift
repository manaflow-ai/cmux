import CmuxNextCloud
import Testing

@Suite struct CloudTryAnotherApproachTests {
    @Test func forksAtLatestTurnAndLeavesParentPlanUntouched() async throws {
        let parent = CloudTryAnotherApproach.Plan(
            workspace: "workspace-gallery", sourceMachine: "vm_parent", session: "parent-session",
            harness: "claude", throughSeq: 6, clientKey: "try-parent-session-6",
            parentLabel: "Try another approach · Fetch retries")
        let result = try await CloudTryAnotherApproach.run(
            chat: "parent-chat", throughSeq: 6,
            prepare: { chat, throughSeq in
                #expect(chat == "parent-chat")
                #expect(throughSeq == 6)
                return parent
            },
            forkMachine: { plan in
                #expect(plan.sourceMachine == "vm_parent")
                #expect(plan.session == "parent-session")
                #expect(plan.throughSeq == 6)
                return .init(id: "run_child", harness: plan.harness, state: "ready", machineId: "vm_child", error: nil)
            },
            forkTranscript: { plan, childMachine in
                #expect(childMachine == "vm_child")
                #expect(plan.session == "parent-session")
                #expect(plan.throughSeq == 6)
                return "child-session"
            },
            openChild: { plan, childMachine, session in
                #expect(childMachine == "vm_child")
                #expect(session == "child-session")
                // The source plan is read at every stage; no operation can rewrite the parent.
                #expect(plan.session == "parent-session")
                #expect(plan.throughSeq == 6)
                return "child-tab"
            })

        #expect(result.childMachine == "vm_child")
        #expect(result.childSession == "child-session")
        #expect(result.childTab == "child-tab")
        #expect(result.parentLabel == parent.parentLabel)
        #expect(result.throughSeq == parent.throughSeq)
        #expect(parent.session == "parent-session")
        #expect(parent.throughSeq == 6)
    }
}
