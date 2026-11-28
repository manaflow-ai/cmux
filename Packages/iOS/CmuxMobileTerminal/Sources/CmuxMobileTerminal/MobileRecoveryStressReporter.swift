#if DEBUG
import CmuxMobileDiagnostics
import Foundation

/// Emits recovery stress markers to both the debug log and stdout.
struct MobileRecoveryStressReporter: Sendable {
    func emit(_ message: String) {
        MobileDebugLog.anchormux(message)
        if let data = "\(message)\n".data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }
}
#endif
