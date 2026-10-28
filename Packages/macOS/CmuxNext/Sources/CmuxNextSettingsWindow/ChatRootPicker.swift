import AppKit
public import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The user-initiated chat root picker. Validation still runs at the shared settings writer.
@MainActor
public struct ChatRootPicker {
    public init() {}

    /// Returns absolute folder paths, or nil when the person cancels.
    public func choose() async -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        // A panel that went away without an answer chose nothing (nil).
        return try? await withOnceContinuation { (continuation: OnceContinuation<[String]?, OnceContinuationError>) in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.urls.map(\.path) : nil)
            }
        }
    }
}
