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
        await first?.value
        await second?.value
        // One failed native launch per recovery; the parallel call joined it.
        #expect(harness.launches.count == afterStartup + 1)
    }
}

/// A runtime over a synthetic helper, private defaults and a frozen clock, so
/// the launch backoff never expires during a test.
@MainActor
private struct DemandRecoveryHarness {
    let fixture: HelperRuntimeFixture
    let defaultsSuite = "cmux.computer-use.demand-recovery.\(UUID().uuidString)"
    let launches = LaunchRecorder()
    let runtime: ComputerUseRuntimeService

    init() throws {
        fixture = try HelperRuntimeFixture()
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        runtime = ComputerUseRuntimeService(
            bundle: fixture.bundle, paths: fixture.paths, userDefaults: defaults,
            uptime: { 100 }, isDisabledByPolicy: { false },
            helperTrust: HelperRuntimeFixture.trustingEveryHelper
        )
        runtime.helperLauncher = launches.launch
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
