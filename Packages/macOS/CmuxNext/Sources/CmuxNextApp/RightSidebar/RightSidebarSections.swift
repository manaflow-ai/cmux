import AppKit
import Observation

/// The right sidebar's section views, by mode: the app registers Vault, Feed,
/// Dock and Cloud; the file explorer registers Files and Find. A mode without
/// a provider has no button and its switch action refuses.
@MainActor
@Observable
final class RightSidebarSections {
    /// Makes one window's view of a section (once per window; the view is kept).
    typealias Provider = @MainActor (WindowController) -> NSView

    @ObservationIgnored private var providers: [RightSidebarMode: Provider] = [:]
    /// The section buttons' SF Symbol images, made off the main thread by ``prewarmIcons()``: CoreUI decodes
    /// each symbol's vectors when its image is made, which cost the first Focus Right Sidebar 47 ms in its turn.
    @ObservationIgnored private var icons: [RightSidebarMode: NSImage] = [:]
    /// Every registered mode's icon is made (tests and the debug report read it).
    private(set) var iconsReady = false
    /// Makes one SF Symbol image; called off the main thread (NSImage is thread-safe to make).
    @ObservationIgnored private let symbolImage: @Sendable (String) -> NSImage?

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

    /// Makes the registered modes' icons on a detached task, once, after the sections are registered (launch).
    func prewarmIcons() {
        let modes = self.modes.filter { icons[$0] == nil }
        guard !modes.isEmpty else { return iconsReady = true }
        let symbolImage = symbolImage
        // task-owner: one pass per launch; the images land on the main actor.
        Task.detached(priority: .utility) { [weak self] in
            let made = modes.compactMap { mode in symbolImage(mode.symbol).map { (mode, $0) } }
            await self?.land(made)
        }
    }

    private func land(_ made: [(RightSidebarMode, NSImage)]) {
        for (mode, image) in made where icons[mode] == nil { icons[mode] = image }
        iconsReady = true
    }
}
