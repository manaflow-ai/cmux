import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The Now Playing card in the bottom-left slot (cx-ouoxo, a preview
/// feature). Not built yet: it never shows.
final class SidebarNowPlayingCardView: NSView {
    var onCommand: ((SidebarNowPlayingCommand) -> Void)?
    private(set) var nowPlaying: SidebarNowPlaying?
    let artworkView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let artistLabel = NSTextField(labelWithString: "")
    let scrubber = SidebarNowPlayingScrubber()
    let previousButton = SidebarIconButton(icon: .mediaPrevious, label: "")
    let playPauseButton = SidebarIconButton(icon: .mediaPlay, label: "")
    let nextButton = SidebarIconButton(icon: .mediaNext, label: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ nowPlaying: SidebarNowPlaying?) {}

    static func height(for nowPlaying: SidebarNowPlaying) -> CGFloat { 0 }
}

/// The card's scrubber. Not built yet.
final class SidebarNowPlayingScrubber: NSView {
    let fill = CALayer()
}
