#if DEBUG
import CMUXDebugLog

@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {
    CMUXDebugLog.logDebugEvent(message())
}
#endif
