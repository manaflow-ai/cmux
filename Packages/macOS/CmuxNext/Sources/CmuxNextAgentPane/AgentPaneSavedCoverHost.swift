public import AppKit

/// The pane's saved page, retained until its live agent page paints.
@MainActor
public protocol AgentPaneSavedCoverHost: NSView {
    /// The saved page currently shown beneath the live page.
    var launchImageView: NSView? { get }
    /// Defers the cover's deadline while the live page has not painted.
    var launchImageMayClear: (() -> Bool)? { get set }
    /// Notifies the live page when the saved picture leaves.
    var onLaunchImageCleared: (() -> Void)? { get set }
    /// Clears only this cover, preserving any replacement installed meanwhile.
    func clearLaunchImage(ifShowing image: NSView)
}

extension AgentPaneView {
    /// Keeps the saved page beneath this view until its paint or loading reveal completes.
    public func holdSavedCover(in host: any AgentPaneSavedCoverHost, rebuilt: Bool) {
        guard let imageView = host.launchImageView else { return }
        standOverPicture()
        holdChromiumPageUntilPainted(rebuilt: rebuilt)
        // A chat's attach can outlast the image deadline; handing over before paint would show an empty pane.
        host.launchImageMayClear = { [weak self] in self?.model.hasPainted ?? true }
        host.onLaunchImageCleared = { [weak self] in self?.pictureBelowWent() }
        loadingView.whenRevealed { [weak host, weak imageView] in
            guard let imageView else { return }
            host?.clearLaunchImage(ifShowing: imageView)
        }
        whenPagePainted { [weak host, weak imageView] in
            guard let imageView else { return }
            host?.clearLaunchImage(ifShowing: imageView)
        }
    }
}
