import Foundation

extension SocketCommandObservability {
    func captureWatchdogSample(for command: Command) async -> WatchdogSample {
        do {
            let sampleURL = try watchdogSampleURL(for: command)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [
                String(ProcessInfo.processInfo.processIdentifier),
                "1",
                "10",
                "-mayDie",
                "-file",
                sampleURL.path
            ]

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            let terminationStatus = try await sampleProcessTerminationStatus(process)

            if terminationStatus != 0 {
                let errorText = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                return WatchdogSample(
                    url: sampleURL,
                    mainThreadExcerpt: nil,
                    errorDescription: "sample exited \(terminationStatus): \(Self.truncated(errorText, maxCharacters: 500))"
                )
            }

            let text = try String(contentsOf: sampleURL, encoding: .utf8)
            return WatchdogSample(
                url: sampleURL,
                mainThreadExcerpt: mainThreadSampleExcerpt(from: text),
                errorDescription: nil
            )
        } catch {
            return WatchdogSample(
                url: nil,
                mainThreadExcerpt: nil,
                errorDescription: String(describing: error)
            )
        }
    }

    private func watchdogSampleURL(for command: Command) throws -> URL {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux/socket-command-watchdog", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-socket-command-watchdog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trimWatchdogSampleFiles(in: directory, keepingNewest: max(0, maxWatchdogSampleFiles - 1))

        let timestampMs = Int(Date().timeIntervalSince1970 * 1_000)
        let method = Self.fileNameComponent(command.method)
        let peerPid = command.peerPid.map(String.init) ?? "unknown"
        return directory.appendingPathComponent(
            "socket-command-\(timestampMs)-\(method)-peer-\(peerPid).sample.txt"
        )
    }

    private func sampleProcessTerminationStatus(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                finished.terminationHandler = nil
                continuation.resume(returning: status)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func trimWatchdogSampleFiles(in directory: URL, keepingNewest maxFiles: Int) {
        guard maxFiles >= 0,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        let sampleFiles = files.filter { $0.lastPathComponent.hasSuffix(".sample.txt") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent > rhs.lastPathComponent
                }
                return lhsDate > rhsDate
            }

        for staleFile in sampleFiles.dropFirst(maxFiles) {
            try? FileManager.default.removeItem(at: staleFile)
        }
    }
}
