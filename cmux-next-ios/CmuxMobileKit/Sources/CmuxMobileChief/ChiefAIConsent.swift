#if os(iOS)
import CmuxMobileModel
import Foundation
import UIKit

/// App Review 5.1.2(i): before the first message goes to Chief, the person is told that
/// what they write, attach or say goes to the third-party AI models that run Chief, and
/// which providers those are, and agrees ("Agree and Send"). Chief's info page turns it
/// off again (``ChiefSettingsView``); with it off, a send asks again.
///
/// Mock content (Debug, the mock account) sends nothing to any AI provider, so it counts
/// as agreed unless a launch sets the key explicitly
/// (`-cmuxMobile.chief.aiSharingConsent NO`, as the App Review gate's reviewer path does).
public enum ChiefAIConsent {
    public static let key = "cmuxMobile.chief.aiSharingConsent"

    /// The person's own answer in this process. It wins over what UserDefaults reads back:
    /// a launch argument (`-cmuxMobile.chief.aiSharingConsent NO`) sits in the argument
    /// domain, which shadows the stored YES, so "Agree and Send" asked again and again and
    /// the draft never went (the App Review gate's reviewer path, run 45334322455).
    /// Written and read on the main thread only (the alert's action, Chief's info toggle, the send gate).
    nonisolated(unsafe) private static var answered: Bool?

    public static var isGranted: Bool {
        if let answered { return answered }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return DeveloperOptions.mockContentEnabled }
        return defaults.bool(forKey: key)
    }

    public static func set(_ granted: Bool) {
        answered = granted
        UserDefaults.standard.set(granted, forKey: key)
    }

    /// Tests: forget this process's answer, so UserDefaults decides again.
    static func forgetAnswerForTesting() { answered = nil }

    /// The providers named to the person. cmux Cloud runs Chief and its agents on
    /// Anthropic's Claude and OpenAI's models; the privacy policy lists AI model providers.
    static var providers: String {
        String(localized: "mobile.chief.aiConsent.providers", defaultValue: "Anthropic (Claude) and OpenAI", bundle: .module)
    }

    static var title: String {
        String(localized: "mobile.chief.aiConsent.title", defaultValue: "Chief Uses AI", bundle: .module)
    }

    static var message: String {
        let format = String(localized: "mobile.chief.aiConsent.message",
                            defaultValue: "To answer, Chief sends what you write, attach or say to the third-party AI models that run it and your agents, from cmux Cloud or your Mac: %@. They process it to write replies, as cmux's Privacy Policy describes. You can turn this off in Chief's info.",
                            bundle: .module)
        return String(format: format, providers)
    }

    static var agreeTitle: String {
        String(localized: "mobile.chief.aiConsent.agree", defaultValue: "Agree and Send", bundle: .module)
    }

    static var privacyTitle: String {
        String(localized: "mobile.chief.aiConsent.privacy", defaultValue: "Privacy Policy", bundle: .module)
    }

    static var notNowTitle: String {
        String(localized: "mobile.chief.aiConsent.notNow", defaultValue: "Not Now", bundle: .module)
    }

    static let privacyURL = URL(string: "https://cmux.com/privacy-policy")!

    /// The alert asked before a send. `agreed` runs after the person agrees; Not Now keeps
    /// the draft in the composer and sends nothing.
    @MainActor
    static func alert(agreed: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "chief.aiConsent"
        alert.addAction(UIAlertAction(title: agreeTitle, style: .default) { _ in
            set(true)
            agreed()
        })
        alert.addAction(UIAlertAction(title: privacyTitle, style: .default) { _ in
            UIApplication.shared.open(privacyURL)
        })
        alert.addAction(UIAlertAction(title: notNowTitle, style: .cancel))
        alert.preferredAction = alert.actions.first
        return alert
    }
}

/// App Review 1.2 and 4.7.1: a way to report a reply from Chief (or a message in a
/// conversation) that is offensive or wrong. It opens a prefilled email to cmux; with no
/// Mail account on the device it opens the support page, which lists the same address.
public enum ChiefReport {
    static let address = "founders@cmux.com"
    static let supportURL = URL(string: "https://cmux.com/support")!

    static var title: String {
        String(localized: "mobile.chief.report.title", defaultValue: "Report a Response…", bundle: .module)
    }

    static var footer: String {
        String(localized: "mobile.chief.report.footer",
                defaultValue: "Report a reply that is offensive, harmful or wrong. cmux reads every report.",
                bundle: .module)
    }

    static func mailURL(conversationID: String?) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = address
        let subject = String(localized: "mobile.chief.report.subject", defaultValue: "Report a Chief response", bundle: .module)
        var body = String(localized: "mobile.chief.report.body", defaultValue: "What was wrong with the response:\n\n", bundle: .module)
        if let conversationID { body += "\n\nConversation: \(conversationID)" }
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return parts.url
    }

    @MainActor
    static func open(conversationID: String?) {
        guard let mail = mailURL(conversationID: conversationID) else {
            UIApplication.shared.open(supportURL)
            return
        }
        UIApplication.shared.open(mail) { opened in
            if !opened { UIApplication.shared.open(supportURL) }
        }
    }
}
#endif
