import Foundation

/// The update channel the user selected in settings (`updates.channel`).
///
/// Release-candidate and stable builds share one bundle identifier, so an install cannot tell
/// from its `Info.plist` which channel it should follow. The app composition root maps the
/// settings value onto this type and injects a provider into ``UpdateController``; the
/// package stays free of the settings dependency. ``UpdateFeedResolver`` applies the
/// selection only to a stable build-time feed; nightly builds keep their own feed.
public enum UpdateChannelSelection: String, Equatable, Sendable {
    /// Follow the shipping release feed (default).
    case stable
    /// Follow the release-candidate feed.
    case rc
}
