import Darwin
import Dispatch
import Foundation

actor SudoSpoolWatcher: SudoSpoolWatching {
    // Dispatch sources are the async-native filesystem notification seam.
    private var sources: [any DispatchSourceFileSystemObject] = []

    func start(
        paths: SudoBrokerPaths,
        onChange: @Sendable @escaping () -> Void
    ) throws {
        stop()
        for directory in [paths.requests, paths.results, paths.states] {
            let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                stop()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: DispatchQueue(label: "com.cmux.sudo-spool-watcher")
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        let activeSources = sources
        sources.removeAll()
        for source in activeSources {
            source.cancel()
        }
    }
}
