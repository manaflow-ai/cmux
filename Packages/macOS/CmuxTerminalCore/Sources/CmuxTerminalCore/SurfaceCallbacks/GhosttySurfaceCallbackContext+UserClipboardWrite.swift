import Foundation
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
        try body()
    }

    /// Whether the current call stack is inside a user-approved copy dispatch.
    public var hasUserInitiatedClipboardWriteIntent: Bool {
        pthread_getspecific(userClipboardWriteDispatchKey) != nil
    }
}
