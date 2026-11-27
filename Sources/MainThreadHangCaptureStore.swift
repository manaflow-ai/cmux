import Foundation

/// Filesystem boundary for main-thread hang captures.
///
/// `@unchecked Sendable` is safe because dependencies are immutable and
/// `FileManager` is thread-safe. Each capture owns distinct metadata/sample
/// files, while retention runs before the sampler starts.
final class MainThreadHangCaptureStore: @unchecked Sendable {
    private let directory: URL
    private let maximumCaptureCount: Int
    private let fileManager: FileManager

    init(
        directory: URL,
        maximumCaptureCount: Int,
        fileManager: FileManager
    ) {
        self.directory = directory
        self.maximumCaptureCount = maximumCaptureCount
        self.fileManager = fileManager
    }

    func prepareCapture(
        capturedAt: Date,
        processIdentifier: Int32,
        stallDuration: TimeInterval,
        appVersion: String,
        appBuild: String
    ) -> (sampleURL: URL, metadataURL: URL)? {
        guard maximumCaptureCount > 0 else { return nil }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            return nil
        }

        prepareForNewCapture()
        let stamp = ISO8601DateFormatter()
            .string(from: capturedAt)
            .replacingOccurrences(of: ":", with: "")
        let identifier = UUID().uuidString.lowercased()
        let baseName = "cmux-hang-\(stamp)-\(processIdentifier)-\(identifier)"
        let sampleURL = directory.appendingPathComponent("\(baseName).sample.txt")
        let metadataURL = directory.appendingPathComponent("\(baseName).metadata.txt")
        let lines = [
            "capturedAt=\(ISO8601DateFormatter().string(from: capturedAt))",
            "pid=\(processIdentifier)",
            "stallSeconds=\(String(format: "%.3f", stallDuration))",
            "appVersion=\(appVersion)",
            "appBuild=\(appBuild)",
            "samplePath=\(sampleURL.path)",
            "",
        ]
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            return nil
        }
        do {
            try data.write(to: metadataURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadataURL.path
            )
            return (sampleURL, metadataURL)
        } catch {
            return nil
        }
    }

    func secureCompletedSample(at sampleURL: URL) {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sampleURL.path
        )
    }

    func appendSampleLaunchError(_ error: Error, to metadataURL: URL) {
        guard let handle = try? FileHandle(forWritingTo: metadataURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "sampleLaunchError=\(String(describing: error))\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func prepareForNewCapture() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var newestDateByCapture: [String: Date] = [:]
        for file in files {
            guard let capture = captureIdentifier(for: file.lastPathComponent) else { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? .distantPast
            newestDateByCapture[capture] = max(newestDateByCapture[capture] ?? .distantPast, date)
        }

        let keepExistingCount = maximumCaptureCount - 1
        let staleCaptures = Set(newestDateByCapture
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key > rhs.key
            }
            .dropFirst(keepExistingCount)
            .map(\.key))
        guard !staleCaptures.isEmpty else { return }
        for file in files {
            guard let capture = captureIdentifier(for: file.lastPathComponent),
                  staleCaptures.contains(capture) else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    private func captureIdentifier(for name: String) -> String? {
        for suffix in [".sample.txt", ".metadata.txt"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }
}
