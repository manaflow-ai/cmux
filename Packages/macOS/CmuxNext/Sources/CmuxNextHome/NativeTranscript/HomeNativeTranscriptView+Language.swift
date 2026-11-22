import AppKit
import CmuxNextCompat
import CmuxNextDesign
import MessagesLabHome

extension HomeNativeTranscriptView {
    /// `app.language` (Leo 2026-11-16: "we gotta add settings for changing lanugages"): the Chief
    /// chat's own words (the composer's "Message", receipts, day separators, menus, Home's rows) are
    /// MessagesLab's strings, a separate package that cannot read cmux's language, so the chat hands
    /// it its bundle's `.lproj` (``Foundation/Bundle/inAppLanguage``) and draws again, live: the
    /// first value in this turn (no English frame first), then each change.
    ///
    /// Reads `DesignSettings.appLanguage` too: the app sets it right after the bundles' language
    /// (`AppLanguageApplier.apply`), so a change reaches here even while the launch warm-up has not
    /// yet adopted MessagesLab's bundle (whose `inAppLanguage` then registers nothing).
    func followLanguage() {
        let (_, later) = ObservationStream.current { Self.stringsPath() }
        transcript.useStrings(Self.strings)
        // task-owner: this view's; it ends at the first change after the view is gone, or at stop().
        languageWatch = Task { [weak self] in
            for await _ in later {
                guard let self, !Task.isCancelled else { return }
                self.transcript.useStrings(Self.strings)
            }
        }
    }

    /// MessagesLab's strings in the app's language.
    private static var strings: Bundle { MessagesLabHomeView.packageStrings.inAppLanguage }

    /// What the chat follows: the strings bundle's path (one value, so an equal re-read wakes nothing).
    private static func stringsPath() -> String {
        _ = DesignSettings.shared.appLanguage
        return strings.bundlePath
    }
}
