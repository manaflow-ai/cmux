import CmuxFoundation
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("DiffViewerPickerCommandRunner")
struct DiffViewerPickerCommandRunnerPackageTests {
    @Test(.timeLimit(.minutes(1)))
    func rejectsBeyondConcurrencyLimitAndReusesCapacity() async throws {
        let commands = ControllableDiffViewerPickerCommands()
        let runner = DiffViewerPickerCommandRunner(
            commandRunner: commands,
            executablePath: "/test/cmux",
            concurrencyLimit: 2
        )
        var starts = commands.starts.makeAsyncIterator()

        let first = Task { await runner.run(arguments: ["first"]) }
        let firstStarted = try #require(await starts.next())
        let second = Task { await runner.run(arguments: ["second"]) }
        let secondStarted = try #require(await starts.next())

        #expect(await runner.run(arguments: ["rejected"]) == nil)
        #expect(await commands.startedIDs == ["first", "second"])

        await commands.complete(firstStarted)
        await commands.complete(secondStarted)
        #expect(await first.value == "first")
        #expect(await second.value == "second")

        let subsequent = Task { await runner.run(arguments: ["subsequent"]) }
        let subsequentStarted = try #require(await starts.next())
        await commands.complete(subsequentStarted)
        #expect(await subsequent.value == "subsequent")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationReleasesCapacity() async throws {
        let commands = ControllableDiffViewerPickerCommands()
        let runner = DiffViewerPickerCommandRunner(
            commandRunner: commands,
            executablePath: "/test/cmux",
            concurrencyLimit: 1
        )
        var starts = commands.starts.makeAsyncIterator()
        var cancellations = commands.cancellations.makeAsyncIterator()

        let active = Task { await runner.run(arguments: ["active"]) }
        let activeID = try #require(await starts.next())
        active.cancel()

        #expect(await cancellations.next() == activeID)
        #expect(await active.value == nil)

        let subsequent = Task { await runner.run(arguments: ["subsequent"]) }
        let subsequentID = try #require(await starts.next())
        await commands.complete(subsequentID)
        #expect(await subsequent.value == "subsequent")
    }
}

private actor ControllableDiffViewerPickerCommands: CommandRunning {
    let starts: AsyncStream<String>
    let cancellations: AsyncStream<String>

    private let startContinuation: AsyncStream<String>.Continuation
    private let cancellationContinuation: AsyncStream<String>.Continuation
    private var completions: [String: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeRegistration: Set<String> = []
    private(set) var startedIDs: [String] = []

    init() {
        (starts, startContinuation) = AsyncStream.makeStream()
        (cancellations, cancellationContinuation) = AsyncStream.makeStream()
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let id = arguments[0]
        startedIDs.append(id)
        startContinuation.yield(id)

        if !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || cancelledBeforeRegistration.remove(id) != nil {
                        continuation.resume()
                    } else {
                        completions[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        if Task.isCancelled {
            cancellationContinuation.yield(id)
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "cancelled"
            )
        }
        return CommandResult(
            stdout: id,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func complete(_ id: String) {
        completions.removeValue(forKey: id)?.resume()
    }

    private func cancel(id: String) {
        if let continuation = completions.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledBeforeRegistration.insert(id)
        }
    }
}
