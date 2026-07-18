import CmuxFoundation
import Darwin
import Foundation

/// Removes the standalone Computer Use helper left behind by pre-embedded cmux builds.
actor ComputerUseLegacyHelperCleanupService {
    typealias ProcessSnapshotProvider = @Sendable () -> [pid_t: String]

    private static let processPathBufferSize = 4_096

    private let computerUseDirectoryURL: URL
    // FileManager is thread-safe; actor isolation serializes this service's use of it.
    private nonisolated(unsafe) let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let processSnapshotProvider: ProcessSnapshotProvider

    init(
        computerUseDirectoryURL: URL = ComputerUseStateRepository.defaultStateDirectory()
            .deletingLastPathComponent(),
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = CommandRunner(),
        processSnapshotProvider: ProcessSnapshotProvider? = nil
    ) {
        self.computerUseDirectoryURL = computerUseDirectoryURL
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.processSnapshotProvider = processSnapshotProvider ?? Self.runningProcessPaths
    }

    func cleanup() async {
        let legacyApplicationURL = computerUseDirectoryURL
            .appendingPathComponent("helper", isDirectory: true)
            .appendingPathComponent("cmux Computer Use.app", isDirectory: true)
            .standardizedFileURL
        let legacyApplicationPathPrefix = legacyApplicationURL.path + "/"
        let processIdentifiers = processSnapshotProvider()
            .compactMap { processIdentifier, executablePath in
                executablePath.hasPrefix(legacyApplicationPathPrefix) ? processIdentifier : nil
            }
            .sorted()

        if !processIdentifiers.isEmpty {
            _ = await commandRunner.run(
                directory: "/",
                executable: "/bin/kill",
                arguments: ["-TERM"] + processIdentifiers.map(String.init),
                timeout: 2
            )
        }

        removeIfPresent(legacyApplicationURL)
        removeIfPresent(computerUseDirectoryURL.appendingPathComponent("cua-daemon.sock"))
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func runningProcessPaths() -> [pid_t: String] {
        let initialProcessCount = Int(proc_listallpids(nil, 0))
        guard initialProcessCount > 0 else { return [:] }

        var processIdentifiers = Array(repeating: pid_t(), count: initialProcessCount + 32)
        let returnedCount = processIdentifiers.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard returnedCount > 0 else { return [:] }

        var paths: [pid_t: String] = [:]
        paths.reserveCapacity(Int(returnedCount))
        for processIdentifier in processIdentifiers.prefix(min(Int(returnedCount), processIdentifiers.count))
        where processIdentifier > 0 {
            var pathBuffer = [CChar](repeating: 0, count: processPathBufferSize)
            let pathLength = proc_pidpath(
                processIdentifier,
                &pathBuffer,
                UInt32(pathBuffer.count)
            )
            guard pathLength > 0 else { continue }
            paths[processIdentifier] = String(cString: pathBuffer)
        }
        return paths
    }
}
