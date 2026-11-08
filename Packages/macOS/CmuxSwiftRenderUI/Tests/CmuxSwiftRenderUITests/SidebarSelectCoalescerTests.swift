import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

struct SidebarSelectCoalescerTests {
    private func select(_ id: String) -> [ActionCommand] {
        [.cmux(method: "workspace.select", params: ["workspace_id": id])]
    }

    @Test func singleSelectRuns() {
        let coalescer = SidebarSelectCoalescer()
        let gen = coalescer.generation(for: select("w1"))
        #expect(gen != nil)
        #expect(coalescer.isCurrent(gen!))
    }

    @Test func burstRunsOnlyTheNewestSelect() {
        // Click burst w1..w4: stamps issue in click order; a FIFO lane then
        // dequeues in the same order, so exactly the stale ones skip and the
        // final click always executes.
        let coalescer = SidebarSelectCoalescer()
        let gens = ["w1", "w2", "w3", "w4"].map { coalescer.generation(for: select($0))! }
        let ran = gens.filter { coalescer.isCurrent($0) }
        #expect(ran == [gens.last!])
    }

    @Test func spacedClicksAllRun() {
        // Clicks slower than the switch never see a newer stamp at dequeue
        // time: stamp, run, stamp, run.
        let coalescer = SidebarSelectCoalescer()
        for id in ["w1", "w2", "w3"] {
            let gen = coalescer.generation(for: select(id))!
            #expect(coalescer.isCurrent(gen))
        }
    }

    @Test func nonSelectAndMultiCommandActionsNeverCoalesce() {
        let coalescer = SidebarSelectCoalescer()
        #expect(coalescer.generation(for: [
            .cmux(method: "workspace.reorder", params: ["workspace_id": "w1", "index": "2"]),
        ]) == nil)
        #expect(coalescer.generation(for: [
            .cmux(method: "workspace.select", params: ["workspace_id": "w1"]),
            .cmux(method: "workspace.action", params: ["action": "pin", "workspace_id": "w1"]),
        ]) == nil)
        #expect(coalescer.generation(for: [.openURL("https://example.com")]) == nil)
        // Interleaved non-selects do not invalidate a pending select.
        let gen = coalescer.generation(for: select("w1"))!
        _ = coalescer.generation(for: [.cmux(method: "workspace.close", params: ["workspace_id": "w2"])])
        #expect(coalescer.isCurrent(gen))
    }
}
