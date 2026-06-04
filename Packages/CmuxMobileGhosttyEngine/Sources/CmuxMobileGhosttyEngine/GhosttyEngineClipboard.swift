#if canImport(UIKit)
import UIKit
#endif

/// The system-clipboard seam the engine uses for libghostty's clipboard
/// callbacks. Injected at construction so tests never touch the real
/// pasteboard.
public struct GhosttyEngineClipboard: Sendable {
    /// Reads the current clipboard string, if any.
    public let read: @MainActor @Sendable () -> String?
    /// Writes a string to the clipboard (or clears it with `nil`).
    public let write: @MainActor @Sendable (String?) -> Void

    /// Creates a clipboard seam.
    /// - Parameters:
    ///   - read: Reads the current clipboard string.
    ///   - write: Writes a string to the clipboard.
    public init(
        read: @escaping @MainActor @Sendable () -> String?,
        write: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        self.read = read
        self.write = write
    }

    #if canImport(UIKit)
    /// The production seam over `UIPasteboard.general`.
    public static var uiPasteboard: GhosttyEngineClipboard {
        GhosttyEngineClipboard(
            read: { UIPasteboard.general.string },
            write: { UIPasteboard.general.string = $0 }
        )
    }
    #endif
}
