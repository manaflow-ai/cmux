public import AppKit

/// The pane's saved-frame cover while an adopted page draws in its new place.
@MainActor
public protocol AgentPaneMoveCoverHost: NSView {
    var launchImageView: NSView? { get }
    var launchImageInvokesResizeCallback: Bool { get set }
    var onLaunchImageCleared: (() -> Void)? { get set }
    func showLaunchImage(_ image: NSImage, limit: Duration)
    func clearLaunchImage(ifShowing image: NSView)
}

extension AgentPaneView {
    /// A parked spare's own frame covers its move until WebKit draws again. Chromium uses its move hold instead.
    public func coverMove(in host: any AgentPaneMoveCoverHost, size: CGSize, limit: Duration, mark: @escaping (String) -> Void) {
        if pageDrawsOverCovers { return placeMovedChromiumPage() }
        let appearance = host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let own = redraw.takeRememberedFrame(size: size, appearance: appearance)
        let image = size == .zero || host.launchImageView != nil ? nil : own ?? AgentPaneNewTabFrame.shared.image(size: size, appearance: appearance)
        mark(image == nil ? "newTab.cover.none \(size) \(String(describing: appearance))" : own != nil ? "newTab.cover.own" : "newTab.cover")
        if let image {
            host.showLaunchImage(image, limit: limit)
            host.launchImageInvokesResizeCallback = false
            host.onLaunchImageCleared = { [weak self] in self?.revealMovedPage() }
        }
        let imageView = image == nil ? nil : host.launchImageView
        hideMovedPage(overPicture: image != nil) { [weak host, weak imageView] in
            mark("newTab.cover.cleared")
            if let imageView { host?.clearLaunchImage(ifShowing: imageView) }
        }
    }
}
