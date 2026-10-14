internal import Darwin

private let userClipboardWriteDispatchKey: pthread_key_t = {
    var key = pthread_key_t()
    precondition(pthread_key_create(&key, nil) == 0)
    return key
}()

extension GhosttySurfaceCallbackContext {
    /// Marks a synchronous copy dispatch as a user-approved clipboard write.
    public func withUserInitiatedClipboardWriteIntent<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        let previousMarker = pthread_getspecific(userClipboardWriteDispatchKey)
        let marker = Unmanaged.passUnretained(self).toOpaque()
        precondition(pthread_setspecific(userClipboardWriteDispatchKey, marker) == 0)
        defer {
            precondition(
                pthread_setspecific(userClipboardWriteDispatchKey, previousMarker) == 0
            )
        }
        return try body()
    }

    /// Whether the current call stack is inside a user-approved copy dispatch.
    public var hasUserInitiatedClipboardWriteIntent: Bool {
        pthread_getspecific(userClipboardWriteDispatchKey)
            == Unmanaged.passUnretained(self).toOpaque()
    }
}
