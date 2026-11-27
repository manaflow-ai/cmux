import CoreServices
import Foundation

/// Immutable callback context retained by FSEvents until queued teardown completes.
final class FileSystemEventReceiver: Sendable {
    let onEvent: @Sendable (FileSystemEventBatch) -> Void

    init(onEvent: @escaping @Sendable (FileSystemEventBatch) -> Void) {
        self.onEvent = onEvent
    }

    func makeContext() -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<FileSystemEventReceiver>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<FileSystemEventReceiver>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
    }
}
