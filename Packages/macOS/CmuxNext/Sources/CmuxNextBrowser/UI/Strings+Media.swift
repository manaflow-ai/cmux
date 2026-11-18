import Foundation

// The media hub's controls (BrowserMediaRowView).
nonisolated extension Strings {
    static var mediaPlay: String { String(localized: "browser.media.play", defaultValue: "Play", bundle: .l10n) }
    static var mediaPause: String { String(localized: "browser.media.pause", defaultValue: "Pause", bundle: .l10n) }
    static var mediaPrevious: String { String(localized: "browser.media.previous", defaultValue: "Previous Track", bundle: .l10n) }
    static var mediaNext: String { String(localized: "browser.media.next", defaultValue: "Next Track", bundle: .l10n) }
    static var mediaMute: String { String(localized: "browser.media.mute", defaultValue: "Mute Tab", bundle: .l10n) }
    static var mediaUnmute: String { String(localized: "browser.media.unmute", defaultValue: "Unmute Tab", bundle: .l10n) }
    static var mediaPictureInPicture: String {
        String(localized: "browser.media.pictureInPicture", defaultValue: "Picture in Picture", bundle: .l10n)
    }
    static var mediaExitPictureInPicture: String {
        String(localized: "browser.media.exitPictureInPicture", defaultValue: "Exit Picture in Picture", bundle: .l10n)
    }
}

/// The media controls' titles for surfaces outside the browser (the
/// sidebar's Now Playing card, cx-ouoxo), the same words as the media hub's.
public nonisolated struct BrowserMediaStrings {
    public nonisolated init() {}
    public static var play: String { Strings.mediaPlay }
    public static var pause: String { Strings.mediaPause }
    public static var previous: String { Strings.mediaPrevious }
    public static var next: String { Strings.mediaNext }
    public static var pictureInPicture: String { Strings.mediaPictureInPicture }
    public static var exitPictureInPicture: String { Strings.mediaExitPictureInPicture }
}
