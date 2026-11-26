#if canImport(UIKit)
import CMUXMobileCore
import Foundation

@testable import CmuxMobileTerminal

extension GhosttySurfaceView {
    /// Applies output with the display link stopped. The link runs the output
    /// apply watchdog, which fails an apply after two seconds and replaces the
    /// surface, and a simulator running the suite in parallel can take that
    /// long to apply one chunk. After 30 seconds this fails the apply, and any
    /// other pending surface operation, instead. The callers' views have no
    /// window, and nothing they call afterward restarts the link.
    func processOutputAndWaitWithTestDeadline(
        _ data: Data,
        terminalConfigTheme: TerminalTheme? = nil
    ) async -> Bool {
        stopDisplayLink()
        let deadline = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(30))
            self?.completePendingSurfaceOperations(returning: false)
        }
        defer { deadline.cancel() }
        return await processOutputAndWait(data, terminalConfigTheme: terminalConfigTheme)
    }
}
#endif
