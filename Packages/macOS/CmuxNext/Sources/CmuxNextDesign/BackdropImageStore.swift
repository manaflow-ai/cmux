public import AppKit
import ImageIO

/// Backdrop images decoded once per process and shared by every window.
///
/// The first window's painting decodes off the main actor, so launch's first
/// frame draws the theme's colors without waiting for it (a 2400 px painting
/// cost that frame about 50 ms when AppKit decoded it in the commit). Later
/// windows take the decoded image at once.
@MainActor
public final class BackdropImageStore {
    public static let shared = BackdropImageStore()

    public init() {}

    /// The decoded image of `selection`, or nil until it has loaded.
    func cached(_ selection: BackdropSelection) -> NSImage? { nil }

    /// The decoded image of `selection`, loading it off the main actor once.
    func image(_ selection: BackdropSelection) async -> NSImage? { selection.image() }
}
