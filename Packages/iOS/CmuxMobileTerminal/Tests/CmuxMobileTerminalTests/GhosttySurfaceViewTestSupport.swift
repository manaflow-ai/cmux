#if canImport(UIKit)
import CMUXMobileCore
import Foundation

@testable import CmuxMobileTerminal

extension GhosttySurfaceView {
    /// Applies output with the display link stopped. The link runs the output
    /// apply watchdog, which fails an apply after two seconds and replaces the
    /// surface, and a simulator running the suite in parallel can take that
    /// long to apply one chunk. An apply still pending after 30 seconds fails
    /// here instead. Nothing a test calls restarts the link on a view without
    /// a window.
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
