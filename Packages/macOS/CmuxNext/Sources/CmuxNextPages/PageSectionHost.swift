public import AppKit
import CmuxNextWakeups

/// A React page filling a sidebar section's slot (the right sidebar's Machines section; any section
/// that is a page). The sidebar makes a section's view the first time the section shows, so the page
/// loads then and not before. The page fills the slot and scrolls inside it: the section's frame never
/// follows its content, so a change of content moves nothing around it.
///
/// It says when the section shows and hides (``onShownChange``: in a window and not hidden, itself or
/// the whole sidebar) and when it comes into or goes out of sight (``onSightChange``: also the window
/// not covered, through the app's one occlusion observer). The page's owner stops what the page does
/// not need while it is hidden (its change streams, its timers) and catches up on the next show.
public final class PageSectionHost: NSView {
    public let page: PageWebView?
    /// The section showed (true) or hid (false); called only on a change.
    public var onShownChange: (@MainActor (Bool) -> Void)? {
        didSet { onShownChange?(isShown) }
    }
    /// The section's window was covered or came back into view while the section shows (``isOnScreen``).
    public var onSightChange: (@MainActor (Bool) -> Void)?
    /// In a window and not hidden.
    public private(set) var isShown = false
    /// The window whose occlusion reports the section follows.
    private weak var sightWindow: NSWindow?

    /// - Parameter page: the section's page (nil when it could not be made: the slot stays empty).
    public init(page: PageWebView?) {
        self.page = page
        super.init(frame: .zero)
        guard let page else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override public var isFlipped: Bool { true }

    /// On screen: shown, and its window not occluded.
    public var isOnScreen: Bool {
        guard isShown, let window else { return false }
        return window.occlusionState.contains(.visible)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followSight()
        updateShown()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        updateShown()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        updateShown()
    }

    private func updateShown() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor
        guard shown != isShown else { return }
        isShown = shown
        onShownChange?(shown)
    }

    private func followSight() {
        if let sightWindow, sightWindow !== window { FrameScheduler.unfollowSight(of: sightWindow, owner: self) }
        sightWindow = window
        guard let window else { return }
        FrameScheduler.followSight(of: window, owner: self) { [weak self] in
            guard let self, isShown else { return }
            onSightChange?(isOnScreen)
        }
    }
}
