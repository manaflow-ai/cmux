import CmuxNextSettings
import Testing

/// Every decision `NotificationPolicy.decide` makes maps to the delivery reason the daemon's
/// `record-notification-delivery` takes: nil when a banner shows, one reason when none does.
@Suite
struct NotificationDeliveryReasonTests {
    private static func reason(_ configure: (inout NotificationPreferences, inout NotificationPolicy.Arrival) -> Void)
        -> NotificationDeliveryReason? {
        var prefs = NotificationPreferences()
        var arrival = NotificationPolicy.Arrival(source: .agent)
        configure(&prefs, &arrival)
        let policy = NotificationPolicy(prefs: prefs)
        let decision = policy.decide(arrival)
        let reason = policy.suppression(of: arrival, decision: decision)
        #expect(decision.desktop == (reason == nil), "a reason exactly when no banner posts")
        return reason
    }

    @Test func wireStringsMatchTheDaemon() {
        #expect(NotificationDeliveryReason.allCases.map(\.rawValue) == [
            "viewed", "typing", "muted", "quiet-hours", "desktop-never", "app-active",
            "poster-no-banner", "permission-denied", "incognito", "digest",
        ])
    }

    @Test func aBannerThatPostsHasNoReason() {
        #expect(Self.reason { prefs, _ in prefs.desktop = .always } == nil)
    }

    @Test func eachSuppressedDecisionHasItsReason() {
        #expect(Self.reason { prefs, arrival in
            prefs.suppressWhileTypingSeconds = 5
            arrival.typedAgo = 1
        } == .typing)
        #expect(Self.reason { _, arrival in arrival.workspaceMuted = true } == .muted)
        #expect(Self.reason { prefs, _ in
            prefs.desktop = .always
            prefs.quietHours = QuietHours(start: 0, end: 24 * 60 - 1)
        } == .quietHours)
        #expect(Self.reason { prefs, _ in prefs.desktop = .never } == .desktopNever)
        #expect(Self.reason { prefs, arrival in
            prefs.desktop = .whenInactive
            arrival.appActive = true
        } == .appActive)
        #expect(Self.reason { prefs, arrival in
            prefs.desktop = .always
            arrival.bannerAllowed = false
        } == .posterNoBanner)
    }

    @Test func aViewedPaneIsViewedUnderEitherRule() {
        #expect(Self.reason { prefs, arrival in
            prefs.desktop = .unlessFocused
            arrival.paneIsViewed = true
        } == .viewed)
    }
}

@Suite
struct NotificationDeliveryReceiptTests {
    private static func receipt(_ suppressed: NotificationDeliveryReason? = nil, digest: Bool = false, incognito: Bool = false,
                                denied: Bool = false) -> (String, String?) {
        let r = NotificationDeliveryReceipt(suppressed: suppressed, digest: digest, incognito: incognito, permissionDenied: denied)
        return (r.desktop, r.reason?.rawValue)
    }

    @Test func aPostedBannerIsShownWithHowItShowed() {
        #expect(Self.receipt() == ("shown", nil))
        #expect(Self.receipt(digest: true) == ("shown", "digest"))
        #expect(Self.receipt(incognito: true) == ("shown", "incognito"))
    }

    @Test func aRefusedBannerIsPermissionDenied() {
        #expect(Self.receipt(denied: true) == ("suppressed", "permission-denied"))
        #expect(Self.receipt(digest: true, denied: true) == ("suppressed", "permission-denied"))
    }

    @Test func aSuppressedArrivalKeepsThePolicysReason() {
        #expect(Self.receipt(.viewed) == ("suppressed", "viewed"))
        #expect(Self.receipt(.muted, denied: true) == ("suppressed", "muted"), "the policy's reason wins over permission")
    }
}
