import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorWorker

/// A failed `read` used to end the drain loop like end of file, so a broken
/// pipe produced empty output with a successful exit status.
@Suite("Simulator pipe read failures")
struct SimulatorPipeReaderTests {
    @Test("A read error is reported instead of ending the output cleanly")
    func directoryReadReportsFailure() async throws {
        let descriptor = open(NSTemporaryDirectory(), O_RDONLY)
        try #require(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let reader = SimulatorPipeReader(handle: handle, name: "test-directory", limit: 1_024)

        await reader.start()
        let result = await reader.waitForEnd()

        #expect(result.failure == SimulatorPipeReadFailure(streamName: "test-directory", code: EISDIR))
        #expect(result.data.isEmpty)
        withExtendedLifetime(handle) {}
    }

    @Test("A descriptor that cannot be read is reported as a read failure")
    func writeOnlyDescriptorReportsFailure() async {
        let pipe = Pipe()
        let reader = SimulatorPipeReader(
            handle: pipe.fileHandleForWriting,
            name: "test-write-end",
            limit: 1_024
        )

        await reader.start()
        let result = await reader.waitForEnd()

        #expect(result.failure == SimulatorPipeReadFailure(streamName: "test-write-end", code: EBADF))
        withExtendedLifetime(pipe) {}
    }

    @Test("A subprocess whose output could not be read fails instead of returning empty output")
    func readFailureFailsTheSubprocessResult() {
        let output = SimulatorPipeReadResult(
            data: Data(),
            truncated: false,
            failure: SimulatorPipeReadFailure(streamName: "cmux-simulator-subprocess-stdout", code: EIO)
        )
        let error = SimulatorPipeReadResult(data: Data(), truncated: false)

        #expect(throws: SimulatorWorkerFailure.self) {
            try SimulatorSubprocessResult.completed(status: 0, output: output, error: error, timedOut: false)
        }
    }

    @Test("Complete output keeps the subprocess result")
    func completeOutputKeepsTheResult() throws {
        let output = SimulatorPipeReadResult(data: Data("rows".utf8), truncated: true)
        let error = SimulatorPipeReadResult(data: Data("warn".utf8), truncated: false)

        let result = try SimulatorSubprocessResult.completed(status: 0, output: output, error: error, timedOut: false)

        #expect(result.status == 0)
        #expect(result.standardOutput == "rows")
        #expect(result.standardError == "warn")
        #expect(result.outputWasTruncated)
        #expect(!result.errorWasTruncated)
        #expect(!result.timedOut)
    }
}
