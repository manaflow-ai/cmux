@testable import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Testing

/// 200 children through each runner leave the app's pipe count where it was (cmuxterm-hq#8747: NIGHTLY held about
/// 2,000 open pipes, 452 of them full, when its main thread waited 391 s in a pipe write). Each child here leaves a
/// grandchild holding its stdout and stderr, as ssh's ControlPersist master does under `remote connect`: an owner
/// that closes its read ends only at end of file keeps two pipes per child open for the grandchild's whole life.
///
/// The count is the whole process's, and other suites run beside this one, so each check allows ``slack`` pipes
/// of theirs; a leak here is 400.
@Suite(.serialized) struct ChildDescriptorLeakTests {
    static let children = 200
    static let slack = 60
    /// A child that exits at once and leaves a grandchild holding stdout and stderr for a while.
    static let leavesAGrandchild = ["-c", "sleep 20 & echo ready"]

    @Test func childProcessClosesItsPipesAfterTheChildExitsEvenWhenAGrandchildHoldsThem() async throws {
        let baseline = try #require(OpenDescriptors.current())
        for _ in 0..<Self.children {
            let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: Self.leavesAGrandchild,
                                     environment: [:], input: Data("secret\n".utf8))
            try child.start()
            #expect(await child.waitForExit() == 0)
        }
        let left = await Self.settledPipes(baseline: baseline.pipes)
        print("ChildDescriptorLeakTests: ChildProcess x\(Self.children): \(left) pipes left open (baseline \(baseline.pipes))")
        #expect(left <= Self.slack, "ChildProcess left \(left) pipes open after \(Self.children) children")
    }

    @Test func childProcessHoldingInputClosesItsPipes() async throws {
        let baseline = try #require(OpenDescriptors.current())
        for _ in 0..<Self.children {
            let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 20 & read line"],
                                     environment: [:])
            try child.startHoldingInput()
            #expect(child.writeInput(line: "go"))
            #expect(await child.waitForExit() == 0)
        }
        let left = await Self.settledPipes(baseline: baseline.pipes)
        print("ChildDescriptorLeakTests: ChildProcess holding input x\(Self.children): \(left) pipes left open")
        #expect(left <= Self.slack, "ChildProcess (held input) left \(left) pipes open after \(Self.children) children")
    }

    @Test func processRunnerLeavesNoPipeOpen() async throws {
        let baseline = try #require(OpenDescriptors.current())
        for _ in 0..<Self.children {
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "read a; sleep 20 & echo $a"],
                                                     environment: [:], stdin: Data("token\n".utf8), timeout: .seconds(30),
                                                     clock: ContinuousClock())
            #expect(result.status == 0)
        }
        let left = await Self.settledPipes(baseline: baseline.pipes)
        let total = (OpenDescriptors.current()?.total ?? 0) - baseline.total
        print("ChildDescriptorLeakTests: ProcessRunner x\(Self.children): \(left) pipes, \(total) descriptors left open")
        #expect(left <= Self.slack, "ProcessRunner left \(left) pipes open after \(Self.children) children")
    }

    @Test func theCountSeesPipesAndTheBudgetNotesACrossing() throws {
        let before = try #require(OpenDescriptors.current())
        let pipes = (0..<10).map { _ in Pipe() }
        let during = try #require(OpenDescriptors.current())
        #expect(during.pipes - before.pipes >= 20)
        #expect(during.total - before.total >= 20)
        withExtendedLifetime(pipes) {}
        #expect(OpenDescriptors.noteBudget(OpenDescriptors(total: 10, pipes: OpenDescriptors.pipeBudget + 1)))
        #expect(!OpenDescriptors.noteBudget(OpenDescriptors(total: 10, pipes: 3)))
    }

    /// Pipes above `baseline` once the drain grace (``ChildOutputEnds/drainGrace``) has passed for every child, at most 10 s.
    static func settledPipes(baseline: Int) async -> Int {
        let deadline = ContinuousClock.now + .seconds(10)
        var left = Int.max
        while ContinuousClock.now < deadline {
            left = (OpenDescriptors.current()?.pipes ?? Int.max) - baseline
            if left <= 0 { return left }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return left
    }
}
