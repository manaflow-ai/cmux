import Foundation
import Testing
@testable import CmuxComputerUse

/// An agent's Computer Use tool call is the moment the daemon must exist: the
/// cmux-cua proxy waits only briefly for the app-owned socket. A failed start
/// earlier in the session must not leave that call to a background backoff
/// that only a Settings toggle used to reset.
@MainActor
struct ComputerUseHelperDemandRecoveryTests {
    @Test func toolInvocationRelaunchesAHelperThatBackoffIsHoldingDown() async throws {
        let harness = try DemandRecoveryHarness()
        defer { harness.remove() }
        let runtime = harness.runtime

        // The first start fails, as a slow or interrupted launch after an
        // update does, and arms the launch backoff.
        await runtime.setEnabled(true)
        #expect(harness.launches.count == 1)

        // Background reconciliation inside the backoff window stays quiet.
        await runtime.setEnabled(true)
        #expect(harness.launches.count == 1)

        // An agent now calls a Computer Use tool. The helper is launched again
        // without the user toggling Computer Use off and on.
        await runtime.requestHelperForToolInvocation()?.value
        #expect(harness.launches.count == 2)

        // The failed on-demand attempt still feeds the backoff, so background
        // reconciliation does not turn a broken helper into a launch loop.
        await runtime.setEnabled(true)
        #expect(harness.launches.count == 2)
    }

    @Test func toolInvocationDoesNotStartADisabledHelper() async throws {
        let harness = try DemandRecoveryHarness()
        defer { harness.remove() }
        let runtime = harness.runtime

        #expect(runtime.requestHelperForToolInvocation() == nil)
        await runtime.setEnabled(true)
        await runtime.setEnabled(false)
        let launchesWhileEnabled = harness.launches.count
        #expect(runtime.requestHelperForToolInvocation() == nil)
        #expect(harness.launches.count == launchesWhileEnabled)
    }

    @Test func concurrentToolInvocationsShareOneRecovery() async throws {
        let harness = try DemandRecoveryHarness()
        defer { harness.remove() }
        let runtime = harness.runtime
        await runtime.setEnabled(true)
        let afterStartup = harness.launches.count

        let first = runtime.requestHelperForToolInvocation()
        let second = runtime.requestHelperForToolInvocation()
        #expect(first != nil)
        #expect(first == second)
        await first?.value
        await second?.value
        // One failed native launch per recovery; the parallel call joined it.
        #expect(harness.launches.count == afterStartup + 1)
    }

    @Test func repeatedToolInvocationsSkipTheBackoffAtMostOncePerInterval() async throws {
        let harness = try DemandRecoveryHarness()
        defer { harness.remove() }
        let runtime = harness.runtime
        await runtime.setEnabled(true)
        await runtime.requestHelperForToolInvocation()?.value
        let afterFirstCall = harness.launches.count

        // An agent retrying straight away against a helper that will not come
        // up is paced by the backoff instead of relaunching on every call.
        await runtime.requestHelperForToolInvocation()?.value
        #expect(harness.launches.count == afterFirstCall)

        harness.clock.now += ComputerUseRuntimeService.toolInvocationStartInterval
        await runtime.requestHelperForToolInvocation()?.value
        #expect(harness.launches.count == afterFirstCall + 1)
    }

    @Test func disablingDuringAToolInvocationRecoveryLaunchesNothing() async throws {
        let harness = try DemandRecoveryHarness()
        defer { harness.remove() }
        let runtime = harness.runtime
        await runtime.setEnabled(true)
        let afterStartup = harness.launches.count

        let recovery = try #require(runtime.requestHelperForToolInvocation())
        await runtime.setEnabled(false)
        await recovery.value
        #expect(harness.launches.count == afterStartup)
        #expect(runtime.requestHelperForToolInvocation() == nil)
    }
}

/// A runtime over a synthetic helper, private defaults and a clock that only
/// a test advances, so the launch backoff never expires on its own.
@MainActor
private struct DemandRecoveryHarness {
    let fixture: HelperRuntimeFixture
    let defaultsSuite = "cmux.computer-use.demand-recovery.\(UUID().uuidString)"
    let launches = LaunchRecorder()
    let clock = ManualUptime()
    let runtime: ComputerUseRuntimeService

    init() throws {
        fixture = try HelperRuntimeFixture()
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, userDefaults: defaults,
            uptime: { [clock] in clock.now }, isDisabledByPolicy: { false },
            helperTrust: HelperRuntimeFixture.trustingEveryHelper
        )
        runtime.helperLauncher = launches.launch
        runtime.helperRegistrar = { _ in }
    }

    func remove() {
        runtime.stopForTermination()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        fixture.files.remove()
    }
}

/// Records helper launches instead of asking LaunchServices to start the
/// synthetic fixture bundle. Every launch fails without a process, so the
/// runtime never tracks (or signals) a real pid.
@MainActor
private final class LaunchRecorder {
    private(set) var count = 0

    var launch: ComputerUseRuntimeService.HelperLauncher {
        { [self] _, _ in
            count += 1
            return nil
        }
    }
}

@MainActor
private final class ManualUptime {
    var now: TimeInterval = 100
}
