import Darwin
import Foundation

struct TextBoxGitIgnoreResolver: Sendable {
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/env")) {
        self.executableURL = executableURL
    }

    func isGitWorkTree(rootURL: URL) async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "rev-parse",
            "--is-inside-work-tree"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            return false
        }
        return await terminationStatus.wait() == 0
    }

    func ignoredRelativePaths(rootURL: URL, relativePaths: [String]) async -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "check-ignore",
            "--stdin"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            return []
        }
        let outputTask = Task<Data, Never> {
            var output = Data()
            do {
                for try await byte in stdout.fileHandleForReading.bytes {
                    output.append(byte)
                }
            } catch {
                return Data()
            }
            return output
        }

        let probePaths = relativePaths + relativePaths.map { "\($0)/" }
        let input = Data((probePaths.joined(separator: "\n") + "\n").utf8)
        guard writeInput(input, to: stdin.fileHandleForWriting) else {
            _ = await outputTask.value
            _ = await terminationStatus.wait()
            return []
        }

        let output = await outputTask.value
        let status = await terminationStatus.wait()
        guard status == 0 || status == 1,
              let outputText = String(data: output, encoding: .utf8) else {
            return []
        }

        return Set(outputText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init))
    }

    func writeInput(_ data: Data, to inputHandle: FileHandle) -> Bool {
        guard fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            try? inputHandle.close()
            return false
        }
        do {
            try inputHandle.write(contentsOf: data)
            try inputHandle.close()
            return true
        } catch {
            try? inputHandle.close()
            return false
        }
    }
}
