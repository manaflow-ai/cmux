#if DEBUG
import AppKit

extension CloudWelcomeWindowController {
    /// Debug previews deliberately bypass the release gate, but still count as seen.
    func presentForDebug(
        over parent: NSWindow?,
        posterShowsTitle: Bool = true,
        posterShowsIcon: Bool = true,
        showsNewBadge: Bool = false,
        footerHasNotNow: Bool = false
    ) {
        Self.markCampaignSeen(in: defaults)
        show(
            over: parent,
            posterShowsTitle: posterShowsTitle,
            posterShowsIcon: posterShowsIcon,
            showsNewBadge: showsNewBadge,
            footerHasNotNow: footerHasNotNow
        )
    }

    func resetForDebug() {
        dismiss()
        defaults.removeObject(forKey: Self.seenVersionDefaultsKey)
        didConsiderLaunchPresentation = false
    }
}
#endif
