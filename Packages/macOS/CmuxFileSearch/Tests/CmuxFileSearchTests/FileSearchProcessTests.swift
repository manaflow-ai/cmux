import Foundation
import Testing

@testable import CmuxFileSearch

@Suite("Child process for searches", .serialized)
struct FileSearchProcessTests {
    private func collect(_ process: FileSearchProcess) async -> Data {
        var data = Data()
        for await chunk in process.standardOutputChunks() { data.append(chunk) }
        return data
    }

    @Test("Arguments reach the child byte for byte, without NFD decomposition")
    func argumentsAreNotNormalized() async throws {
        let composed = "caf\u{E9}"  // NFC "café"
        let process = try FileSearchProcess(command: FileSearchCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\"", "sh", composed]
        ))
        let output = await collect(process)
        let exit = await process.waitForExit()

        #expect(exit.status == 0)
        #expect(Array(output) == Array(composed.utf8))
    }

    @Test("Standard input is delivered and closed")
    func standardInput() async throws {
        let process = try FileSearchProcess(command: FileSearchCommand(
            executablePath: "/bin/sh",
            arguments: ["-s"],
            standardInput: Data("printf 'from stdin'; exit 3\n".utf8)
        ))
        let output = await collect(process)
        let exit = await process.waitForExit()

        #expect(String(decoding: output, as: UTF8.self) == "from stdin")
        #expect(exit.status == 3)
    }

    @Test("Terminate stops the whole process group, including grandchildren")
    func terminateKillsGroup() async throws {
        // The grandchild keeps stdout open; the stream can only end once it dies too.
        let process = try FileSearchProcess(command: FileSearchCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo ready; /bin/sleep 600 & wait"]
        ))
        var iterator = process.standardOutputChunks().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == "ready\n")

        process.terminate()
        while await iterator.next() != nil {}
        let exit = await process.waitForExit()
        #expect(exit.status == 128 + SIGTERM)
    }

    @Test("A missing executable reports ripgrep as not found")
    func missingExecutable() async {
        let completion = await RipgrepStreamingSearch.run(
            command: FileSearchCommand(executablePath: "/nonexistent/rg", arguments: []),
            matchLimit: 10,
            sink: FileSearchBatchMailbox()
        )
        #expect(completion == .failed(.ripgrepNotFound))
    }

    @Test("Stderr is returned for diagnostics")
    func standardErrorCaptured() async throws {
        let process = try FileSearchProcess(command: FileSearchCommand(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo boom >&2; exit 2"]
        ))
        _ = await collect(process)
        let exit = await process.waitForExit()
        #expect(exit.status == 2)
        #expect(exit.standardError == "boom\n")
    }
}
