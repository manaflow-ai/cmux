import AppKit

/// The right sidebar's section views, by mode: the app registers Vault, Feed,
/// Dock and Cloud; the file explorer registers Files and Find. A mode without
/// a provider has no button and its switch action refuses.
@MainActor
final class RightSidebarSections {
    /// Makes one window's view of a section (once per window; the view is kept).
    typealias Provider = @MainActor (WindowController) -> NSView

    private var providers: [RightSidebarMode: Provider] = [:]

    func register(_ mode: RightSidebarMode, _ provider: @escaping Provider) {
        providers[mode] = provider
    }

    /// The modes with a section, in mode bar order.
    var modes: [RightSidebarMode] { RightSidebarMode.allCases.filter { providers[$0] != nil } }

    func makeView(_ mode: RightSidebarMode, for window: WindowController) -> NSView? {
        providers[mode]?(window)
    }
}
