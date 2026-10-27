#if canImport(Darwin)
import CmuxNextCompat
import Darwin
import Foundation

/// kqueue sources on one history database, its `-wal` and its folder; any
/// event calls `onChange`. A file the browser replaces (or a `-wal` made
/// later) is opened again on the next event. Holds the folder grant's
/// security scope while it watches.
final class HistoryFileWatch: Sendable {
    let file: URL
    private let scope: URL?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.import-history-sync", qos: .utility)
    /// The open sources by path; nil once cancelled, so a re-arm racing `cancel` opens nothing.
    private let sources = Mutex<[String: any DispatchSourceFileSystemObject]?>([:])

    init(file: URL, scope: URL?, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.scope = scope.flatMap { $0.startAccessingSecurityScopedResource() ? $0 : nil }
        self.onChange = onChange
        queue.async { [self] in armMissing() }
    }

    deinit {
        cancel()
    }

    private var paths: [String] { [file.path, file.path + "-wal", file.deletingLastPathComponent().path] }

    /// Stops every source and gives the folder's scope back; later calls do nothing.
    func cancel() {
        guard let open = sources.withLock({ sources in defer { sources = nil }; return sources }) else { return }
        open.values.forEach { $0.cancel() }
        scope?.stopAccessingSecurityScopedResource()
    }

    /// On `queue`: opens a source for each path that has none (or lost its file).
    private func armMissing() {
        for path in paths where sources.withLock({ $0.map { $0[path] == nil } ?? false }) {
            // SAFETY: the path is a NUL-terminated copy Swift keeps alive for the call; open only reads it.
            let descriptor = unsafe open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                                   queue: queue)
            // wakeup-allow: kqueue file event (no timer); the sync coalesces reads behind a DemandTimer
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    sources.withLock { $0?[path] = nil }
                }
                armMissing()
                onChange()
            }
            source.setCancelHandler { close(descriptor) }
            // Stored only while the watch is live; cancelled already, it closes again at once.
            let stored = sources.withLock { sources -> Bool in
                guard sources != nil else { return false }
                sources?[path] = source
                return true
            }
            source.resume()
            if !stored { source.cancel() }
        }
    }
}
#endif
