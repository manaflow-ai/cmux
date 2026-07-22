import Darwin
import Foundation

/// Process-backed Git command runner used by the local artifact repository.
struct SystemArtifactGitCommandRunner: ArtifactGitCommandRunning {
    func terminationStatus(arguments: [String]) throws -> Int32 {
        let process = makeProcess(arguments: arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func run(
        arguments: [String],
        standardInput: Data?
    ) throws -> (terminationStatus: Int32, standardOutput: Data) {
        let process = makeProcess(arguments: arguments)
        let outputFile = try makeUnlinkedOutputFile()
        process.standardOutput = outputFile
        let inputPipe = standardInput.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        if let standardInput, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        try outputFile.seek(toOffset: 0)
        let standardOutput = try outputFile.readToEnd() ?? Data()
        try outputFile.close()
        return (process.terminationStatus, standardOutput)
    }

    private func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func makeUnlinkedOutputFile() throws -> FileHandle {
        var template = Array("\(NSTemporaryDirectory())cmux-artifact-git.XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        unlink(template)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
