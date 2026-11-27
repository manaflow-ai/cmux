internal import Darwin

// Unlike the paste marker, this stores the context itself: a pointer event
// targets one surface, so other surfaces' writes must not match.
private let pointerSelectionCopyDispatchKey: pthread_key_t = {
    var key = pthread_key_t()
    precondition(pthread_key_create(&key, nil) == 0)
    return key
}()

extension GhosttySurfaceCallbackContext {
    /// Marks a synchronous pointer dispatch to this surface. libghostty copies
    /// on select inside that call, so a clipboard write seen during it is a
    /// copy-on-select copy, never a keyboard copy or an OSC 52 write.
    public func withPointerSelectionCopyIntent<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        let key = pointerSelectionCopyDispatchKey
        let previousMarker = pthread_getspecific(key)
        let marker = Unmanaged.passUnretained(self).toOpaque()
        precondition(pthread_setspecific(key, marker) == 0)
        defer {
            precondition(pthread_setspecific(key, previousMarker) == 0)
        }
        return try body()
    }

    /// Whether the current call stack is inside ``withPointerSelectionCopyIntent(_:)``.
    public var hasPointerSelectionCopyIntent: Bool {
        pthread_getspecific(pointerSelectionCopyDispatchKey)
            == Unmanaged.passUnretained(self).toOpaque()
    }
}
