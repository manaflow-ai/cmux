import AppKit
import CmuxNextDesign
import CmuxNextTasks
import CmuxNextWakeups
import Testing

/// A hidden Tasks tab does no SwiftUI work: 100 model changes while its node is
/// hidden run 0 bodies, and showing it runs 1.
@MainActor
struct TasksHostViewGateTests {
    @Test func aHiddenTasksPageRunsNoBodyForModelChanges() throws {
        let source = MockTasksSource()
        let model = TasksModel(source: source)
        model.start()
        defer { model.stop() }
        let host = TasksHostView(model: model, layout: .list)
        let gate = try #require(host.visibilityGate)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        let app = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab:tasks", own: .visible, parent: app)
        let ledger = ObservationLedger()
        gate.follow(tab, observations: ledger)
        func pass() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        pass()
        let shown = gate.bodyEvaluations.total
        #expect(shown >= 1, "the pane rendered once shown")

        tab.set(.hidden)
        #expect(gate.isGated)
        // `TasksView` reads the scope; each set invalidates it.
        for index in 0..<100 {
            model.scope = index.isMultiple(of: 2) ? .mine : .all
            pass()
        }
        #expect(gate.bodyEvaluations.total == shown, "no body while hidden: \(gate.bodyEvaluations)")

        tab.set(.visible)
        pass()
        #expect(gate.bodyEvaluations.total == shown + 1, "one body on show: \(gate.bodyEvaluations)")
        let entry = try #require(ledger.snapshot(matching: "Hosting.TasksHostView").first)
        #expect(entry.hiddenBodyEvaluations == 0, "debug.observations: \(entry)")
    }
}
