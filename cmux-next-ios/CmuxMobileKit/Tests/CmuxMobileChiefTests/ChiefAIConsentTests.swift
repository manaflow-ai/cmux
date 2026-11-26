#if os(iOS)
import Foundation
import XCTest
@testable import CmuxMobileChief

/// App Review 5.1.2(i): "Agree and Send" must hold, even when a launch argument seeded the
/// answer. The App Review gate launches with `-cmuxMobile.chief.aiSharingConsent NO`; that
/// value sits in UserDefaults' argument domain, which shadows the YES the alert stores, so
/// the send gate asked again after every Agree and the draft never went (run 45334322455,
/// testChiefOpensAndAMessageSendsWithAReply: "the sent message must show; app alert: Chief Uses AI").
final class ChiefAIConsentTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        ChiefAIConsent.forgetAnswerForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.removeObject(forKey: ChiefAIConsent.key)
        ChiefAIConsent.forgetAnswerForTesting()
        super.tearDown()
    }

    func testAgreeingHoldsOverALaunchArgumentThatSaidNo() {
        var arguments = savedArguments
        arguments[ChiefAIConsent.key] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertFalse(ChiefAIConsent.isGranted, "the launch argument asks before the first send")

        ChiefAIConsent.set(true)
        XCTAssertTrue(ChiefAIConsent.isGranted, "after Agree and Send, the send goes; it must not ask again")

        ChiefAIConsent.set(false)
        XCTAssertFalse(ChiefAIConsent.isGranted, "turning sharing off in Chief's info asks again")
    }
}
#endif
