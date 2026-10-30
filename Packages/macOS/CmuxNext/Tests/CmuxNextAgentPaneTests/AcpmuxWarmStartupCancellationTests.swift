import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Quit cancels the shared startup wait even when acpmux keeps logging without becoming ready.
@Suite(.timeLimit(.minutes(1)))
struct AcpmuxWarmStartupCancellationTests {
    @Test func cancelWarmInterruptsDaemonStartup() async throws {
        let environment = try AcpmuxLaunchReadyWaitTests.environment("""
        i=0; while [ $i -lt 60 ]; do echo loading-for-cancel; sleep 0.1; i=$((i+1)); done
        """)
        defer { try? FileManager.default.removeItem(at: environment.home.deletingLastPathComponent()) }
        let host = AcpmuxHost(environment: environment)
        let warming = Task {
            do { try await host.warm(sessionIds: ["restored"]); return false }
            catch { return true }
        }
        defer { warming.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while (try? String(contentsOfFile: environment.logPath, encoding: .utf8).contains("loading-for-cancel")) != true {
            try #require(ContinuousClock.now < deadline, "stand-in daemon never started")
            try await Task.sleep(for: .milliseconds(20))
        }
        let cancelledAt = ContinuousClock.now
        warming.cancel()
        #expect(await warming.value)
        #expect(await host.hasWarmedSessions == false, "a cancelled startup never claims a daemon")
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
    }
}
