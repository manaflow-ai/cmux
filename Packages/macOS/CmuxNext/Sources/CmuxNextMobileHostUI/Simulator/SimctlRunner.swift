import Foundation

/// Runs `xcrun simctl …` off the cooperative pool and returns its output.
struct SimctlRunner: Sendable {
    struct Failure: Error, Hashable { let status: Int32 }

    func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["simctl"] + arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                let stdin = Pipe()
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                do {
                    try process.run()
                    if let input {
                        stdin.fileHandleForWriting.write(input)
                        try? stdin.fileHandleForWriting.close()
                    }
                    // concurrency-allow: runs on a global dispatch queue, never the main thread or the cooperative pool.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    // concurrency-allow: same global dispatch queue; simctl exits right after its output ends.
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: Failure(status: process.terminationStatus))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
