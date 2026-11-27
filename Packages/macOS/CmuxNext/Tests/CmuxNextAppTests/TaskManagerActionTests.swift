import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Darwin
import Foundation
import Testing

/// The Task Manager (Window menu, palette, `cmux app task-manager`): a page tab that lists
/// cmux's processes with CPU and memory, and Kill Process (`taskManager.killProcess`, the row
/// menu, the page's button and `cmux app kill-process`), which asks first and ends only a cmux
/// process: never the app itself, a daemon, a process on another machine or a process cmux
/// did not start.
@MainActor @Suite(.serialized)
struct TaskManagerActionTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    static func kill(_ process: String, confirmed: Bool = true) -> ActionInvocation {
        let invocation = ActionInvocation(arguments: ["process": .string(process)], origin: .cli)
        return confirmed ? invocation.confirmed() : invocation
    }

    /// A process this test (the app here) started: a cmux process.
    static func child() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    static func ended(_ process: Process, within timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return !process.isRunning
    }

    @Test func taskManagerAndKillProcessAreAvailable() {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: "palette.openTaskManager") == nil)
        #expect(services.registry.unavailableReason(for: "taskManager.killProcess") == nil)
    }

    @Test func killProcessEndsAProcessCmuxStarted() async throws {
        let services = Self.services()
        let child = try Self.child()
        defer { if child.isRunning { child.terminate() } }
        var ran = false
        let refusal = services.registry.capturingRefusal {
            ran = services.registry.perform("taskManager.killProcess", invocation: Self.kill("\(child.processIdentifier)"))
        }
        #expect(ran)
        #expect(refusal == nil)
        #expect(await Self.ended(child), "the confirmed kill ends the process")
        #expect(child.terminationReason == .uncaughtSignal)
    }

    @Test func aScriptedKillMustBeConfirmed() async throws {
        let services = Self.services()
        let child = try Self.child()
        defer { if child.isRunning { child.terminate() } }
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("taskManager.killProcess", invocation: Self.kill("\(child.processIdentifier)", confirmed: false))
        }
        #expect(refusal == ActionRegistry.confirmationRequiredReason(for: "taskManager.killProcess"))
        #expect(!(await Self.ended(child, within: .milliseconds(300))), "nothing ends without confirm")
    }

    @Test(arguments: ["self", "1", "m-cloud:4242", "not-a-pid"])
    func killProcessRefusesWhatItMustNotEnd(_ process: String) {
        let services = Self.services()
        let argument = process == "self" ? "\(getpid())" : process
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("taskManager.killProcess", invocation: Self.kill(argument))
        }
        #expect(refusal?.isEmpty == false, "\(argument) is refused with a reason")
    }
}
