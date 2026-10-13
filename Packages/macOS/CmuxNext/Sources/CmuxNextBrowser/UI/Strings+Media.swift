import Foundation

// The media hub's controls (BrowserMediaRowView).
nonisolated extension Strings {
    static var mediaPlay: String { String(localized: "browser.media.play", defaultValue: "Play", bundle: .module) }
    static var mediaPause: String { String(localized: "browser.media.pause", defaultValue: "Pause", bundle: .module) }
    static var mediaPrevious: String { String(localized: "browser.media.previous", defaultValue: "Previous Track", bundle: .module) }
    static var mediaNext: String { String(localized: "browser.media.next", defaultValue: "Next Track", bundle: .module) }
    static var mediaMute: String { String(localized: "browser.media.mute", defaultValue: "Mute Tab", bundle: .module) }
    static var mediaUnmute: String { String(localized: "browser.media.unmute", defaultValue: "Unmute Tab", bundle: .module) }
}
