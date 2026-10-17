public import Foundation

/// The toolbar's "extension crashed, click to reload" button.
///
/// A crashed pinned action that is visible shows its own warning glyph; every
/// other crashed extension (unpinned, or a pin that overflowed into the
/// Extensions popover) would otherwise be invisible, so the toolbar shows one
/// warning button for them before the Extensions button. Clicking it reloads
/// them all, as cmux-next's crash indicator does.
public struct BrowserExtensionCrashIndicator: Equatable, Sendable {
    /// The crashed extensions the button stands for, in store order.
    public var extensionIDs: [String]
    /// Their names, for the tooltip and VoiceOver.
    public var names: [String]

    /// True when the toolbar shows the button.
    public var isShown: Bool { !extensionIDs.isEmpty }

    /// Picks the crashed extensions that have no visible toolbar button.
    ///
    /// - Parameters:
    ///   - extensions: The profile's extensions.
    ///   - visibleActionIDs: The pinned actions shown in the toolbar row.
    public init(extensions: [BrowserExtensionInfo], visibleActionIDs: Set<String>) {
        let crashed = extensions.filter { $0.isTerminated && !visibleActionIDs.contains($0.id) }
        extensionIDs = crashed.map(\.id)
        names = crashed.map(\.name)
    }
}
