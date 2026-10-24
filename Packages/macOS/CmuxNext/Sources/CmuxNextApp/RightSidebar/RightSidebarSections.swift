import AppKit

/// The right sidebar's section views, by mode: the app registers Vault, Feed,
/// Dock and Cloud; the file explorer registers Files and Find. A mode without
/// a provider has no button and its switch action refuses.
@MainActor
final class RightSidebarSections {
    /// Makes one window's view of a section (once per window; the view is kept).
    typealias Provider = @MainActor (WindowController) -> NSView

    private var providers: [RightSidebarMode: Provider] = [:]
    /// The section buttons' SF Symbol images, made and drawn once off the main thread by ``prewarmIcons()``:
    /// making a symbol's image and CoreUI's decode of its vectors (on its first draw) cost the first Focus
    /// Right Sidebar 47 ms in its turn.
    private var icons: [RightSidebarMode: NSImage] = [:]
    /// Makes one SF Symbol image; called off the main thread (an image made and drawn on one thread is safe there).
    private let symbolImage: @Sendable (String) -> NSImage?

    /// - Parameter symbolImage: Makes an SF Symbol image by name (tests count the calls).
    init(symbolImage: @escaping @Sendable (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) {
        self.symbolImage = symbolImage
    }

    func register(_ mode: RightSidebarMode, _ provider: @escaping Provider) {
        providers[mode] = provider
    }

    /// The modes with a section, in mode bar order.
    var modes: [RightSidebarMode] { RightSidebarMode.allCases.filter { providers[$0] != nil } }

    func makeView(_ mode: RightSidebarMode, for window: WindowController) -> NSView? {
        providers[mode]?(window)
    }

    /// The icon of `mode`'s button: the prewarmed one, else made now (only before ``prewarmIcons()`` landed).
    func icon(_ mode: RightSidebarMode) -> NSImage? {
        if let icon = icons[mode] { return icon }
        let made = symbolImage(mode.symbol)
        icons[mode] = made
        return made
    }

    /// Makes the registered modes' icons on a detached task, once, after the sections are registered (launch),
    /// and draws each one there into a bitmap, so the symbol's vectors are decoded off the main thread too
    /// (CoreUI decodes them on an image's first draw, not when it is made).
    ///
    /// - Returns: The task, done once every icon landed on the main actor (nil: nothing to make).
    @discardableResult
    func prewarmIcons() -> Task<Void, Never>? {
        let modes = self.modes.filter { icons[$0] == nil }
        guard !modes.isEmpty else { return nil }
        let symbolImage = symbolImage
        // task-owner: one pass per launch (AppServices keeps the sections); the images land on the main actor.
        return Task.detached(priority: .utility) { [weak self] in
            let made = modes.compactMap { mode -> (RightSidebarMode, NSImage)? in
                guard let image = symbolImage(mode.symbol) else { return nil }
                _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                return (mode, image)
            }
            await self?.land(made)
        }
    }

    private func land(_ made: [(RightSidebarMode, NSImage)]) {
        for (mode, image) in made where icons[mode] == nil { icons[mode] = image }
    }
}
