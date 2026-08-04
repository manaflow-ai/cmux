import Foundation

/// Lock-guarded record of the HTTP method AND body byte count that reached a
/// redirect's TARGET, so a test can read them synchronously right after the
/// awaited upload completes (``RedirectingURLProtocol`` records before it
/// finishes loading the response).
final class RedirectTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _targetMethod: String?
    private var _targetBodyByteCount: Int?
    func record(targetMethod: String?, bodyByteCount: Int?) {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = targetMethod
        _targetBodyByteCount = bodyByteCount
    }
    func targetMethod() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _targetMethod
    }
    func targetBodyByteCount() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return _targetBodyByteCount
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _targetMethod = nil
        _targetBodyByteCount = nil
    }
}
