public import Foundation

extension RemoteRdStreamTransport {
    // MARK: Recording as you go

    /// Starts recording the main screen into a new MP4 at `url` (the Rust
    /// core copies each frame it hands out, no re-encoding); `done` hears
    /// whether the file could be created, on the transport's queue.
    public func startRecording(to url: URL, done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            do {
                try engine.core.startRecording(path: url.path)
                done(true)
            } catch {
                done(false)
            }
        }
    }

    /// Finishes the recording; `done` hears the frames in the file (nil when
    /// a write failed), on the transport's queue.
    public func stopRecording(done: @escaping @Sendable (Int?) -> Void) {
        queue.async { [self] in
            done(try? engine.core.stopRecording())
        }
    }
}
