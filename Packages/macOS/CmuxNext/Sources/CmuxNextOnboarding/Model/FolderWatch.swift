import Foundation

/// Calls `onChange` on the main actor whenever a folder's entries change
/// (a file written, renamed or removed). Stops on `cancel` or deinit.
@MainActor
final class FolderWatch {
    private var source: (any DispatchSourceFileSystemObject)?

    init?(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } } // main-proof: dispatch source on queue: .main
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    isolated deinit { source?.cancel() }
}
