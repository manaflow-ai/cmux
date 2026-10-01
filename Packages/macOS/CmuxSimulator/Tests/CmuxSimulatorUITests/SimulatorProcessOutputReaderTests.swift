import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator process output reader")
struct SimulatorProcessOutputReaderTests {
    @Test("An invalid descriptor reports duplication failure after draining")
    func invalidDescriptorReportsFailure() async {
        let reader = SimulatorProcessOutputReader(fileDescriptor: -1)
        var output: [String] = []

        for await batch in reader.batches() { output += batch }

        #expect(output.isEmpty)
        #expect(reader.failure == .duplicateDescriptor(errorNumber: EBADF))
    }

    @Test("A write-only descriptor reports a read error instead of EOF")
    func writeOnlyDescriptorReportsReadFailure() async throws {
        // /dev/null is poll-ready, but reading its write-only fd fails with EBADF.
        let descriptor = Darwin.open("/dev/null", O_WRONLY)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        let reader = SimulatorProcessOutputReader(fileDescriptor: descriptor)
        var output: [String] = []

        for await batch in reader.batches() { output += batch }

        #expect(output.isEmpty)
        #expect(reader.failure == .read(errorNumber: EBADF))
    }

    @Test("Clean EOF preserves output without reporting a failure", arguments: ["", "first\nlast"])
    func cleanEOF(output: String) async throws {
        let pipe = Pipe()
        let reader = SimulatorProcessOutputReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForWriting.write(contentsOf: Data(output.utf8))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        var received: [String] = []

        for await batch in reader.batches() { received += batch }

        #expect(received.joined() == output)
        #expect(reader.failure == nil)
    }
}
