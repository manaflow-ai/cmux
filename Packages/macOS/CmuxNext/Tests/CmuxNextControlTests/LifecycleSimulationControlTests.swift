#if DEBUG
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `debug.simulate.wake` and `debug.simulate.display` (LifecycleSimulationControl, p02-threads 307): lifecycle-sweep.py
/// runs the app's sleep, wake and display observers through them, so each must post exactly its notices, in their
/// order, from their sender, on their own center; an unknown phase posts nothing. On the test's own centers
/// (check-test-notification-centers.sh), with the test's own names.
@MainActor @Suite
struct LifecycleSimulationControlTests {
    /// Every notice a center delivers, by name and sender, in order.
    @MainActor final class Heard {
        var notices: [(name: Notification.Name, sender: ObjectIdentifier?)] = []
        private var tokens: [NSObjectProtocol] = []

        init(_ names: [Notification.Name], on center: NotificationCenter) {
            for name in names {
                tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notice in
                    let heard = (name: notice.name, sender: (notice.object as AnyObject?).map(ObjectIdentifier.init))
                    MainActor.assumeIsolated { self?.notices.append(heard) }
                })
            }
        }
    }

    let notices = LifecycleSimulationControl.Notices(
        sleep: [Notification.Name("test.willSleep"), Notification.Name("test.screensDidSleep")],
        wake: [Notification.Name("test.didWake"), Notification.Name("test.screensDidWake")],
        display: Notification.Name("test.screenParameters"))
    let workspaceCenter = NotificationCenter()
    let appCenter = NotificationCenter()
    let workspace = NSObject()
    let application = NSObject()

    var every: [Notification.Name] { notices.sleep + notices.wake + [notices.display] }

    func control() -> LifecycleSimulationControl {
        LifecycleSimulationControl(notices: notices, workspaceCenter: workspaceCenter, workspace: workspace,
                                   appCenter: appCenter, application: application)
    }

    @Test func sleepThenWakePostTheirNoticesInOrderOnTheWorkspaceCenterFromTheWorkspace() throws {
        let onWorkspace = Heard(every, on: workspaceCenter)
        let onApp = Heard(every, on: appCenter)
        let control = control()

        let slept = try control.wake(phase: "sleep")
        let woke = try control.wake(phase: "wake")

        #expect(onWorkspace.notices.map(\.name) == notices.sleep + notices.wake)
        #expect(onWorkspace.notices.allSatisfy { $0.sender == ObjectIdentifier(workspace) })
        #expect(onApp.notices.isEmpty, "a sleep or wake notice reached the app's center")
        #expect(slept["posted"]?.arrayValue?.compactMap(\.stringValue) == notices.sleep.map(\.rawValue))
        #expect(slept["phase"]?.stringValue == "sleep")
        #expect(woke["phase"]?.stringValue == "wake")
        #expect(woke["synthetic"]?.boolValue == true)
    }

    @Test func aDisplayChangeIsOneNoticeOnTheAppCenterFromTheApp() {
        let onWorkspace = Heard(every, on: workspaceCenter)
        let onApp = Heard(every, on: appCenter)

        let reply = control().display()

        #expect(onApp.notices.map(\.name) == [notices.display])
        #expect(onApp.notices.first?.sender == ObjectIdentifier(application))
        #expect(onWorkspace.notices.isEmpty)
        #expect(reply["posted"]?.arrayValue?.compactMap(\.stringValue) == [notices.display.rawValue])
    }

    @Test func anUnknownOrMissingPhaseIsRefusedAndPostsNothing() {
        let onWorkspace = Heard(every, on: workspaceCenter)
        let control = control()

        for phase in [nil, "resume", ""] as [String?] {
            #expect(throws: ControlError.self) { try control.wake(phase: phase) }
        }
        #expect(onWorkspace.notices.isEmpty)
    }

    @Test func bothMethodsAreRegisteredUnderTheNamesTheSweepCalls() {
        #expect(control().methods.map(\.name) == ["debug.simulate.wake", "debug.simulate.display"])
    }
}
#endif
