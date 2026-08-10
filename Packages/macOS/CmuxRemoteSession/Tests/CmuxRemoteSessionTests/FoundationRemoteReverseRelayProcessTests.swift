import CmuxFoundation
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Foundation reverse relay process")
struct FoundationRemoteReverseRelayProcessTests {
    @Test("Termination waits for the complete stderr tail")
    func terminationDrainsStderr() async throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            i=0
            while [ "$i" -lt 1000 ]; do
              printf 'diagnostic-noise-%s\n' "$i" >&2
              i=$((i + 1))
            done
            printf 'Error: remote port forwarding failed for listen port 64044\n' >&2
            printf 'Connection to example.com closed.\n' >&2
            printf 'debug1: cleanup\n' >&2
            exit 255
            """,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe
        )
        let (details, continuation) = AsyncStream<String?>.makeStream()

        try process.run()
        relayProcess.captureTermination { detail in
            continuation.yield(detail)
            continuation.finish()
        }

        var iterator = details.makeAsyncIterator()
        #expect(
            await iterator.next()
                == "Error: remote port forwarding failed for listen port 64044"
        )
        #expect(process.terminationStatus == 255)
    }

    @Test("Termination bounds draining inherited stderr writers")
    func terminationBoundsInheritedStderr() async throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            sleep 3 &
            printf 'proxy diagnostic\n' >&2
            exit 23
            """,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe,
            stderrDrainGracePeriod: 0.05
        )
        let (details, continuation) = AsyncStream<String?>.makeStream()

        try process.run()
        relayProcess.captureTermination { detail in
            continuation.yield(detail)
            continuation.finish()
        }

        var iterator = details.makeAsyncIterator()
        #expect(await iterator.next() == "proxy diagnostic")
        #expect(process.terminationStatus == 23)
    }

    @Test("Exact OpenSSH forward confirmation reports startup")
    func forwardConfirmationReportsStartup() async throws {
        let marker = RemoteSessionCoordinator.reverseRelayForwardSuccessMarker(
            relayPort: 64_044,
            localRelayPort: 55_001
        )
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            printf 'debug1: %s\n' \(marker.shellSingleQuoted) >&2
            sleep 0.1
            exit 0
            """,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe
        )
        let (startups, startupContinuation) = AsyncStream<Void>.makeStream()
        let (terminations, terminationContinuation) =
            AsyncStream<String?>.makeStream()

        try process.run()
        relayProcess.captureLifecycle(
            startupMarker: marker,
            startupTimeout: 1,
            startupHandler: {
                startupContinuation.yield()
                startupContinuation.finish()
            },
            terminationHandler: { detail in
                terminationContinuation.yield(detail)
                terminationContinuation.finish()
            }
        )

        var startupIterator = startups.makeAsyncIterator()
        #expect(await startupIterator.next() != nil)
        var terminationIterator = terminations.makeAsyncIterator()
        #expect(await terminationIterator.next() != nil)
        #expect(process.terminationStatus == 0)
    }

    @Test("Missing forward confirmation hits a bounded startup deadline")
    func missingForwardConfirmationTerminates() async throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 3"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe,
            stderrDrainGracePeriod: 0.05
        )
        let startupRecorder = SynchronousEventRecorder()
        let (terminations, continuation) = AsyncStream<String?>.makeStream()

        try process.run()
        relayProcess.captureLifecycle(
            startupMarker: "marker-that-never-arrives",
            startupTimeout: 0.05,
            startupHandler: {
                startupRecorder.record()
            },
            terminationHandler: { detail in
                continuation.yield(detail)
                continuation.finish()
            }
        )

        var iterator = terminations.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(startupRecorder.count == 0)
        #expect(!process.isRunning)
    }

    @Test("Startup deadline force-kills a process that ignores SIGTERM")
    func startupDeadlineForceKillsAfterGracePeriod() async throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            trap '' TERM
            printf 'ready\\n'
            while :; do :; done
            """,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe,
            stderrDrainGracePeriod: 0.05,
            terminationGracePeriod: 0.05
        )
        let startupRecorder = SynchronousEventRecorder()
        let (terminations, continuation) = AsyncStream<String?>.makeStream()

        try process.run()
        let readiness = stdoutPipe.fileHandleForReading.readData(ofLength: 6)
        #expect(String(data: readiness, encoding: .utf8) == "ready\n")
        relayProcess.captureLifecycle(
            startupMarker: "marker-that-never-arrives",
            startupTimeout: 0.05,
            startupHandler: {
                startupRecorder.record()
            },
            terminationHandler: { detail in
                continuation.yield(detail)
                continuation.finish()
            }
        )

        var iterator = terminations.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(startupRecorder.count == 0)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }
}
