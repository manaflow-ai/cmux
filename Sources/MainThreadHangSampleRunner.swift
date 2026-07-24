import Foundation

/// Process-launch boundary for `/usr/bin/sample`.
///
/// `@unchecked Sendable` is safe because the active-process registry is
/// confined to `queue`; callers only enqueue immutable capture requests.
final class MainThreadHangSampleRunner: @unchecked Sendable {
    private let executableURL: URL
    private let queue = DispatchQueue(
        label: "com.cmuxterm.main-thread-hang-sampler",
        qos: .utility
    )
    private var activeSamples: [UUID: Process] = [:]

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func startSample(
        processIdentifier: Int32,
        sampleURL: URL,
        onCompletion: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        queue.async { [self] in
            let identifier = UUID()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "\(processIdentifier)",
                "5",
                "1",
                "-file",
                sampleURL.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                queue.async { [self] in
                    activeSamples.removeValue(forKey: identifier)
                    onCompletion()
                }
            }

            do {
                try process.run()
                activeSamples[identifier] = process
            } catch {
                onFailure(error)
            }
        }
    }
}
