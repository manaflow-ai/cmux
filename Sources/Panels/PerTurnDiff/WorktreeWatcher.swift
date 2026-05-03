import Foundation
import CoreServices

/// Watches a worktree path via FSEvents; coalesces bursts and emits debounced change callbacks.
/// FSEvents stream runs on a utility queue; debounce timer fires on the main queue.
final class WorktreeWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let queue = DispatchQueue(label: "com.cmux.WorktreeWatcher", qos: .utility)
    private let debounceMs: Int
    private var debounceWorkItem: DispatchWorkItem?
    private let onChange: () -> Void

    init(path: String, debounceMs: Int = 100, onChange: @escaping () -> Void) {
        self.path = path
        self.debounceMs = debounceMs
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvents(count: count)
        }
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.05,  // 50ms internal latency for FSEvents
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let s else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.debounceWorkItem?.cancel()
            self?.debounceWorkItem = nil
        }
    }

    private func handleEvents(count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounceWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(self.debounceMs),
                execute: work
            )
        }
    }
}
