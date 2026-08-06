public import Foundation
internal import AppKit

/// The production ``SystemFileOpening`` conformer: opens files through the
/// asynchronous `NSWorkspace` API so Launch Services cannot stall the main
/// actor while resolving or launching the default application.
public struct NSWorkspaceFileOpener: SystemFileOpening {
    /// Creates an opener backed by the shared `NSWorkspace`.
    public init() {}

    @MainActor
    public func openWithSystemDefault(_ url: URL) {
        NSWorkspace.shared.open(
            url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: { _, _ in }
        )
    }
}
