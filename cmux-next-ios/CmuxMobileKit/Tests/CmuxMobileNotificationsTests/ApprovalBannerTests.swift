import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// A permission request outside the app reads as the Mac's approval prompt for a
/// streaming device (`MacScreenApprovalView`): "<Agent> wants to act on <Mac>",
/// the request under it, Deny leading and the single-use Allow trailing.
@Suite struct ApprovalBannerTests {
    static func permission(_ options: [(String, String)], workspace: String? = "cmux", previews: Bool = true) -> PushPayload {
        PushPayload(mac: SealedPushTests.mac, macName: "Mac mini", kind: .permission, eventId: "p-1", agent: "Claude Code",
                    workspace: workspace, sessionId: "s-1", permissionId: "perm-1", title: "rm -rf build",
                    options: options.map { PushOption(id: $0.0, label: $0.0, kind: PushOption.Kind(rawValue: $0.1)) },
                    previews: previews)
    }

    /// The service extension's own code (`ServicePush.opened`) on a sealed permission push.
    @Test func aSealedPermissionOpensAsTheMacsPrompt() throws {
        let (keys, macKey, pushKey) = try SealedPushTests.setUp()
        // Signed in as the paired account: the service extension opens its sealed pushes.
        try PushActiveAccount(store: keys.store).update(userID: "u1")
        let payload = Self.permission([("Allow once", "allow_once"), ("Deny", "reject_once")])
        let delivered = UNMutableNotificationContent()
        delivered.userInfo = try SealedPushTests.sealedPush(macKey: macKey, pushKey: pushKey, payload: payload)
        let shown = try #require(ServicePush().opened(delivered, keys: keys))
        #expect(shown.title == "Claude Code wants to act on Mac mini")
        #expect(shown.subtitle == "cmux")
        #expect(shown.body == "rm -rf build")
        #expect(shown.categoryIdentifier == PushCategory.permission.rawValue)
        // What it wrote is what the box says: the buttons still act.
        let gate = PushTrustGate(trust: keys.trust(), keys: keys)
        let verdict = gate.verdict(userInfo: shown.userInfo,
                                   shown: .init(title: shown.title, subtitle: shown.subtitle, body: shown.body, category: shown.categoryIdentifier))
        guard case .trusted(let opened) = verdict else { Issue.record("its own banner was refused: \(verdict)"); return }
        #expect(ApprovalBanner(payload: opened)?.allow?.id == "Allow once")
        // The words the phone wrote before this change no longer act over this box.
        let old = PushTrustGate.Shown(title: "Claude Code needs permission", subtitle: "cmux · Mac mini", body: "rm -rf build",
                                      category: PushCategory.permission.rawValue)
        guard case .openOnly = gate.verdict(userInfo: shown.userInfo, shown: old) else { Issue.record("acted on another banner"); return }
    }

    @Test func theCardReadsAsTheMacsPrompt() throws {
        let banner = try #require(ApprovalBanner(payload: Self.permission([("Allow once", "allow_once"), ("Deny", "reject_once")])))
        #expect(banner.title == "Claude Code wants to act on Mac mini")
        #expect(banner.scope == "Asks to run this in cmux.")
        #expect(banner.detailLabel == "Request" && banner.detail == "rm -rf build")
        #expect(banner.deny?.id == "Deny" && banner.allow?.id == "Allow once" && banner.more.isEmpty)
        // No workspace: the Mac alone, as the Mac's "wants to control this Mac".
        let bare = try #require(ApprovalBanner(payload: Self.permission([], workspace: nil)))
        #expect(bare.scope == "Asks to run this." && bare.deny == nil && bare.allow == nil)
        #expect(PushBanner(payload: Self.permission([], workspace: nil))
            == PushBanner(title: "Claude Code wants to act on Mac mini", subtitle: nil, body: "rm -rf build"))
    }

    /// The Feed's options decide the answers (`phoneOptions`); the card only lays them out.
    @Test func answersFollowTheFeedsOptions() throws {
        // A lasting grant is hidden next to a single-use Allow (acpmux refuses it from a phone).
        let once = try #require(ApprovalBanner(payload: Self.permission([("yes", "allow_once"), ("always", "allow_always"), ("no", "reject_once")])))
        #expect(once.allow?.id == "yes" && once.deny?.id == "no" && once.more.isEmpty)
        // Only a lasting Allow offered: it is the prominent answer, as the Feed offers it.
        let always = try #require(ApprovalBanner(payload: Self.permission([("always", "allow_always"), ("no", "reject_once")])))
        #expect(always.allow?.id == "always" && always.deny?.id == "no")
        // More than one of a side: the rest go compact under the two.
        let many = try #require(ApprovalBanner(payload: Self.permission([("always", "allow_always"), ("session", "allow_always"),
                                                                         ("no", "reject_once"), ("never", "reject_always")])))
        #expect(many.allow?.id == "always" && many.deny?.id == "no" && many.more.map(\.id) == ["session", "never"])
        // A lasting reject listed first: Deny is still the single-use one, as the lock screen's Deny.
        let lastingFirst = try #require(ApprovalBanner(payload: Self.permission([("always", "allow_always"), ("never", "reject_always"),
                                                                                 ("no", "reject_once")])))
        #expect(lastingFirst.deny?.id == "no" && lastingFirst.more.map(\.id) == ["never"])
        // An option id sent twice shows once.
        let twice = try #require(ApprovalBanner(payload: Self.permission([("always", "allow_always"), ("always", "allow_always"),
                                                                          ("no", "reject_once")])))
        #expect(twice.allow?.id == "always" && twice.more.isEmpty)
        // A tap on an answer sends that option, as the rows did.
        var form = PushForm(payload: Self.permission([("yes", "allow_once"), ("no", "reject_once")]))
        #expect(form.tap(try #require(once.deny)) == .deny(optionID: "no"))
        #expect(form.tap(try #require(once.allow)) == .allow(optionID: "yes"))
    }

    /// An empty title or workspace counts as none, as the Worker's `||` does.
    @Test func emptyTextCountsAsNone() throws {
        var p = Self.permission([], workspace: "")
        p.title = ""
        p.body = "Run the deploy script"
        let banner = try #require(ApprovalBanner(payload: p))
        #expect(banner.detail == "Run the deploy script" && banner.scope == "Asks to run this.")
        #expect(PushBanner(payload: p).body == "Run the deploy script")
    }

    /// Show previews off: the lock screen still says only the kind and the Mac.
    @Test func previewsOffKeepTheFixedBanner() {
        let hidden = Self.permission([("Allow once", "allow_once")], previews: false)
        #expect(PushBanner(payload: hidden) == PushBanner(title: "Claude Code needs permission", body: "Mac mini"))
    }

    @Test func onlyAPermissionIsAnApproval() {
        #expect(ApprovalBanner(payload: SealedPushTests.question) == nil)
        #expect(ApprovalBanner(payload: PushPayload(mac: "m", kind: .completed)) == nil)
    }
}
