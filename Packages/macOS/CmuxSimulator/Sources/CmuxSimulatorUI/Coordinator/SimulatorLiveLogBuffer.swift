import Foundation

/// Byte-bounded log storage that keeps UTF-8 scanning and trimming off MainActor.
actor SimulatorLiveLogBuffer {
    private static let maximumBytes = 200_000
    private static let retainedBytes = 150_000
    private static let publicationInterval = Duration.milliseconds(100)

    private let clock = ContinuousClock()
    private var bytes = Data()
    private var lastPublication: ContinuousClock.Instant?

    func reset() {
        bytes.removeAll(keepingCapacity: true)
        lastPublication = nil
    }

    func append(_ text: String) -> String? {
        bytes.append(contentsOf: text.utf8)
        if bytes.count > Self.maximumBytes {
            bytes = Data(bytes.suffix(Self.retainedBytes))
        }
        let now = clock.now
        if let lastPublication,
           lastPublication.duration(to: now) < Self.publicationInterval {
            return nil
        }
        lastPublication = now
        return decodedSnapshot()
    }

    func snapshot() -> String {
        decodedSnapshot()
    }

    var storedByteCount: Int { bytes.count }

    private func decodedSnapshot() -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
