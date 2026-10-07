import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// `notification-program-status-v1`: the app builds a program status
/// notification's body from localized words by kind and state, then the
/// program's message as plain text. The daemon's title stays; a notification
/// without a program status keeps the daemon's body.
struct ProgramStatusNotificationTextTests {
    private static func status(_ state: NotificationProgramStatus.State, _ kind: NotificationProgramStatus.Kind?,
                               _ msg: String?) -> NotificationProgramStatus {
        NotificationProgramStatus(state: state, kind: kind, msg: msg)
    }

    @Test func theWordingFollowsTheKindAndState() {
        #expect(Self.status(.blocked, .permission, "Apply?").localizedBody == "Needs approval: Apply?")
        #expect(Self.status(.blocked, .question, "Which region?").localizedBody == "Asks a question: Which region?")
        #expect(Self.status(.blocked, .auth, nil).localizedBody == "Needs sign-in")
        #expect(Self.status(.blocked, nil, nil).localizedBody == "Needs input")
        #expect(Self.status(.error, nil, "exit 2").localizedBody == "Failed: exit 2")
        #expect(Self.status(.error, nil, nil).localizedBody == "Failed")
        #expect(Self.status(.blocked, .permission, "").localizedBody == "Needs approval")
    }

    @Test func theMessageStaysPlainText() {
        let msg = "[open](https://example.com) `rm -rf ~` %@ %1$@"
        #expect(Self.status(.blocked, nil, msg).localizedBody == "Needs input: \(msg)")
    }

    @Test func bannerAndFeedUseTheLocalizedBody() throws {
        let data = Data(#"{"notification":1,"title":"terraform","body":"Needs approval: Apply?","level":"warning","source":"terminal","program_status":{"state":"blocked","kind":"auth","msg":"Apply?"}}"#.utf8)
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: data)
        #expect(NotificationCenterService.body(of: notification) == "Needs sign-in: Apply?")
        var mirror = FeedMirrorPreferences()
        mirror.terminal = .full
        #expect(NotificationCenterService.feedContent(notification, source: .terminal, mirror: mirror)!
            == ("terraform", "Needs sign-in: Apply?"))

        let plain = try JSONDecoder().decode(DaemonNotification.self, from: Data(
            #"{"notification":2,"title":"T","body":"B","level":"info"}"#.utf8))
        #expect(NotificationCenterService.body(of: plain) == "B")
    }

    @Test func panelRowsUseTheLocalizedBody() throws {
        let entries = try NotificationsPanelTests.entries(#"""
        [{"id":"ntf_a","title":"make","body":"Failed: exit 2","level":"error","created_at_ms":2000,"acknowledged":false,"program_status":{"state":"error","kind":null,"msg":"exit 1"}},
         {"id":"ntf_b","title":"Build","body":"done","level":"info","created_at_ms":1000,"acknowledged":true}]
        """#)
        let rows = NotificationsPanelRow.make(entries) { _ in nil }
        #expect(rows.map(\.title) == ["make", "Build"])
        #expect(rows.map(\.body) == ["Failed: exit 1", "done"])
    }

    /// The compiled `Localizable.strings` of one localization in the app bundle.
    private static func compiled(_ language: String) throws -> [String: String] {
        let lproj = try #require(Bundle.module.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
        let url = URL(fileURLWithPath: lproj).appending(path: "Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "no \(language) Localizable.strings")
    }

    @Test func theWordsShipInEnglishAndJapanese() throws {
        let expected: [String: (en: String, ja: String)] = [
            "notification.programStatus.needsApproval": ("Needs approval", "承認が必要です"),
            "notification.programStatus.asksQuestion": ("Asks a question", "質問があります"),
            "notification.programStatus.needsSignIn": ("Needs sign-in", "サインインが必要です"),
            "notification.programStatus.needsInput": ("Needs input", "入力が必要です"),
            "notification.programStatus.failed": ("Failed", "失敗しました"),
            "notification.programStatus.withMessage": ("%1$@: %2$@", "%1$@：%2$@"),
        ]
        let en = try Self.compiled("en")
        let ja = try Self.compiled("ja")
        for (key, value) in expected {
            #expect(en[key] == value.en, "\(key)")
            #expect(ja[key] == value.ja, "\(key)")
        }
    }
}
