import CoreServices
import Foundation

/// The FSEvents stream and its retained sink, stopped once when the watch
/// stream ends.
// FSEventStreamRef and the raw context pointer are not Sendable; they are touched only on the
// watcher's delivery queue (stop runs there), after FSEventStreamStart on the creating thread.
nonisolated struct DirectoryWatcherStreamHandle: @unchecked Sendable {
    let ref: FSEventStreamRef
    let info: UnsafeMutableRawPointer

    /// Stops, invalidates and releases the stream, then the sink the context retained.
    func stop() {
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        Unmanaged<DirectoryWatcherSink>.fromOpaque(info).release()
    }
}
