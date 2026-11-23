import CmuxMobileBilling
import CmuxMobileBillingUI
import Foundation
import Observation
import StoreKit
import StoreKitTest
import SwiftUI
import UIKit
import XCTest

/// The products in `CmuxBilling.storekit`, as `com.cmux.app` sells them.
enum CmuxProduct {
    static let goMonthly = "com.cmux.app.go.monthly"
    static let proMonthly = "com.cmux.app.pro.monthly"
    static let proYearly = "com.cmux.app.pro.yearly"
    static let maxMonthly = "com.cmux.app.max.monthly"
    static let maxYearly = "com.cmux.app.max.yearly"

    static let all: [BillingProductReference] = [
        BillingProductReference(productID: goMonthly, planID: .go),
        BillingProductReference(productID: proMonthly, planID: .pro),
        BillingProductReference(productID: proYearly, planID: .pro),
        BillingProductReference(productID: maxMonthly, planID: .max),
        BillingProductReference(productID: maxYearly, planID: .max),
    ]

    static func plan(of productID: String) -> BillingPlanID {
        all.first { $0.productID == productID }?.planID ?? .free
    }
}

/// The payload of a StoreKit 2 transaction JWS, the fields the cmux server
/// reads (`web/services/billing/apple`). Dates are milliseconds since 1970.
struct TransactionPayload: Decodable, Equatable {
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let purchaseDate: Double?
    let expiresDate: Double?
    let revocationDate: Double?
    let revocationReason: Int?
    let transactionReason: String?
    let environment: String?
    let appAccountToken: String?
    let isUpgraded: Bool?

    var transactionID: UInt64 { UInt64(transactionId) ?? 0 }
    var originalTransactionID: UInt64 { UInt64(originalTransactionId) ?? 0 }
    var expires: Date? { expiresDate.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var revoked: Date? { revocationDate.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// Decodes the middle (payload) segment of a compact JWS.
    init(jws: String) throws {
        let segments = jws.split(separator: ".")
        guard segments.count == 3 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a JWS")) }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "payload is not base64url"))
        }
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Stands in for the cmux web server's `/api/billing/apple/*` routes.
///
/// The real server refuses every Xcode-environment transaction by design
/// (`400 invalid_transaction`: StoreKit Testing signs with a local
/// certificate, not Apple's root CA), so these tests cannot post to it. This
/// double answers the way it does for a Sandbox or Production transaction:
/// it decodes each posted JWS, keeps the newest transaction per original
/// transaction id (an older payload never overwrites a newer one), and grants
/// that subscription's plan while it is neither revoked nor past its expiry.
/// A billing grace period and an expiry reach the real server from Apple
/// (the App Store Server API, or `DID_FAIL_TO_RENEW` and `EXPIRED`
/// notifications), so a test reports them with
/// ``receiveGracePeriod(originalTransactionID:until:)`` and
/// ``receiveExpiredNotification(originalTransactionID:)``.
@MainActor
@Observable
final class FakeCmuxBillingServer: BillingAPI {
    struct Post: Equatable {
        let jws: String
        let payload: TransactionPayload
    }

    let appAccountToken = UUID(uuidString: "0B5E7A2C-3D4F-4A1B-9C8D-7E6F5A4B3C2D")!
    /// Every JWS the app posted, in order.
    private(set) var posts: [Post] = []
    /// Number of account-token loads.
    private(set) var accountLoads = 0
    /// The newest transaction per original transaction id.
    private var subscriptions: [UInt64: TransactionPayload] = [:]
    /// Grace periods Apple reported, by original transaction id.
    private var graceUntil: [UInt64: Date] = [:]
    /// Original transaction ids Apple reported expired.
    private var expired: Set<UInt64> = []

    nonisolated init() {}

    func accountToken() async throws -> BillingAccount {
        accountLoads += 1
        let granting = grantingSubscription
        return BillingAccount(
            appAccountToken: appAccountToken,
            eligible: true,
            reason: nil,
            currentPlan: BillingCurrentPlan(
                planID: granting.map { CmuxProduct.plan(of: $0.productId) } ?? .free,
                source: granting == nil ? .none : .apple
            ),
            products: CmuxProduct.all
        )
    }

    func submitTransaction(signedTransactionInfo: String) async throws -> BillingTransactionReceipt {
        let payload: TransactionPayload
        do {
            payload = try TransactionPayload(jws: signedTransactionInfo)
        } catch {
            throw BillingAPIError.rejected(statusCode: 400)
        }
        posts.append(Post(jws: signedTransactionInfo, payload: payload))
        print("[storekit] server got #\(payload.transactionId) orig=\(payload.originalTransactionId) \(payload.productId) "
            + "reason=\(payload.transactionReason ?? "-") expires=\(payload.expires.map { "\($0)" } ?? "-") "
            + "revoked=\(payload.revoked.map { "\($0)" } ?? "-") upgraded=\(payload.isUpgraded ?? false) token=\(payload.appAccountToken ?? "-")")
        // A transaction without a token (an offer code, or a purchase StoreKit
        // completed outside the app's purchase call) is claimed by the
        // signed-in user, as the server does while no other account owns it.
        if let token = payload.appAccountToken, token.lowercased() != appAccountToken.uuidString.lowercased() {
            throw BillingAPIError.accountMismatch
        }
        let original = payload.originalTransactionID
        if let stored = subscriptions[original], stored.transactionId != payload.transactionId,
           (stored.purchaseDate ?? 0) > (payload.purchaseDate ?? 0) {
            // An older transaction (a refund of a past period, the upgraded
            // Pro after a Max upgrade) records only itself.
        } else {
            subscriptions[original] = payload
        }
        let current = subscriptions[original] ?? payload
        let status = current.revoked != nil ? "revoked" : (grants(current) ? "active" : "expired")
        return BillingTransactionReceipt(
            planID: grants(current) ? CmuxProduct.plan(of: current.productId) : .free,
            status: status,
            expiresAt: current.expires.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    /// Apple's `EXPIRED` notification for a subscription.
    func receiveExpiredNotification(originalTransactionID: UInt64) {
        expired.insert(originalTransactionID)
    }

    /// Apple reporting a billing grace period for a subscription.
    func receiveGracePeriod(originalTransactionID: UInt64, until: Date) {
        graceUntil[originalTransactionID] = until
    }

    /// The posts of purchases (not renewals). storekitd can still deliver a
    /// renewal from an earlier test's session after clearTransactions(), so
    /// "nothing was posted" and "the first post" checks read this.
    var purchasePosts: [Post] { posts.filter { $0.payload.transactionReason == "PURCHASE" } }

    /// The posts of one subscription, by its original transaction id.
    func posts(original: UInt64) -> [Post] { posts.filter { $0.payload.originalTransactionID == original } }

    /// The posts whose transaction was refunded.
    var refundPosts: [Post] { posts.filter { $0.payload.revocationDate != nil } }

    private var grantingSubscription: TransactionPayload? {
        subscriptions.values
            .filter(grants)
            .max { CmuxProduct.plan(of: $0.productId) < CmuxProduct.plan(of: $1.productId) }
    }

    private func grants(_ payload: TransactionPayload) -> Bool {
        guard payload.revoked == nil, payload.isUpgraded != true,
              !expired.contains(payload.originalTransactionID) else { return false }
        let now = Date()
        if let grace = graceUntil[payload.originalTransactionID], grace > now { return true }
        return payload.expires.map { $0 > now } ?? true
    }
}

/// One SKTestSession over `CmuxBilling.storekit` with the real
/// ``LiveStoreKitClient`` and ``BillingModel`` on top.
@MainActor
final class StoreKitRig {
    let session: SKTestSession
    let server = FakeCmuxBillingServer()
    let store = LiveStoreKitClient()
    let model: BillingModel

    init() throws {
        let url = try XCTUnwrap(Bundle(for: StoreKitRig.self).url(forResource: "CmuxBilling", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        session.shouldEnterBillingRetryOnRenewal = false
        session.billingGracePeriodIsEnabled = false
        session.timeRate = .realTime
        model = BillingModel(api: server, store: store, analytics: nil)
    }

    /// Waits for StoreKit to finish the previous test's work (a billing retry
    /// can still renew after its test ended), then starts the listener and
    /// loads the account and offers.
    func start() async throws {
        try await settleStoreKit()
        model.start()
        await model.refresh()
        XCTAssertEqual(model.offers.count, 5, "every product in CmuxBilling.storekit loads (\(String(describing: model.offersFailure)))")
    }

    func stop() async throws {
        model.stop()
        session.shouldEnterBillingRetryOnRenewal = false
        session.billingGracePeriodIsEnabled = false
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        try await settleStoreKit()
    }

    /// Clears StoreKit Testing's transactions and waits until StoreKit lists
    /// no entitlement and no unfinished transaction.
    private func settleStoreKit() async throws {
        session.clearTransactions()
        try await eventually("no transactions left") {
            if await self.entitledProductIDs().isEmpty, await self.unfinishedIDs().isEmpty { return true }
            self.session.clearTransactions()
            return false
        }
    }

    func offer(_ productID: String) throws -> BillingOffer {
        try XCTUnwrap(model.offers.first { $0.product.id == productID }, "offer \(productID)")
    }

    /// StoreKit Testing's view of every transaction, for identifiers and logs.
    func testTransactions(_ productID: String? = nil) -> [SKTestTransaction] {
        session.allTransactions().filter { productID == nil || $0.productIdentifier == productID }
    }

    /// The ids of StoreKit's unfinished transactions.
    func unfinishedIDs() async -> [UInt64] {
        var ids: [UInt64] = []
        for await verification in Transaction.unfinished {
            if case .verified(let transaction) = verification { ids.append(transaction.id) }
        }
        return ids
    }

    /// The product ids StoreKit lists in `Transaction.currentEntitlements`.
    func entitledProductIDs() async -> [String] {
        var ids: [String] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification { ids.append(transaction.productID) }
        }
        return ids
    }

    /// StoreKit's subscription statuses for the cmux group, read through a
    /// product of the group.
    func subscriptionStatuses() async throws -> [Product.SubscriptionInfo.Status] {
        let products = try await Product.products(for: [CmuxProduct.proMonthly])
        let subscription = try XCTUnwrap(products.first?.subscription)
        return try await subscription.status
    }

    /// Prints StoreKit Testing's transaction table, so the log shows what
    /// each step changed.
    func dump(_ label: String) {
        let lines = ["  (\(session.allTransactions().count) transactions)"] + session.allTransactions().map { t in
            "  #\(t.identifier) orig=\(t.originalTransactionIdentifier) \(t.productIdentifier) state=\(t.state.rawValue) "
                + "autoRenew=\(t.autoRenewingEnabled) expires=\(t.expirationDate.map { "\($0)" } ?? "-") "
                + "cancel=\(t.cancelDate.map { "\($0)" } ?? "-") issue=\(t.hasPurchaseIssue) askToBuy=\(t.pendingAskToBuyConfirmation)"
        }
        print("[storekit] \(label)\n" + lines.joined(separator: "\n"))
    }

    /// Waits until StoreKit's own state (entitlements, renewal info) shows a
    /// change made through the session. storekitd applies a session change
    /// asynchronously and offers no signal for it, so this re-reads every
    /// 100 ms until the deadline.
    func eventually(
        _ what: String,
        timeout: Duration = .seconds(20),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if try await condition() { return }
        XCTFail("StoreKit did not show \(what) within \(timeout)", file: file, line: line)
        throw CancellationError()
    }

    /// Waits until `condition` holds, re-checking on each change of the
    /// observable state it reads (the model and the server double). The
    /// timeout bounds a test that would otherwise hang; it is not a delay.
    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(20),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        if condition() { return }
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer { deadline.cancel() }
        func arm() {
            withObservationTracking { _ = condition() } onChange: { continuation.yield() }
        }
        arm()
        for await _ in changes {
            if condition() { return }
            arm()
        }
        if condition() { return }
        XCTFail("timed out after \(timeout) waiting until \(what)", file: file, line: line)
        throw CancellationError()
    }
}

/// Renders the real plans screen for the model's current state and attaches
/// a light and a dark PNG to the test.
@MainActor
enum PlansSnapshot {
    static let size = CGSize(width: 393, height: 1500)

    static func attach(_ model: BillingModel, name: String, to test: XCTestCase) async {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = await render(model, style: style)
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(style == .dark ? "dark" : "light").png"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
    }

    /// Shows the screen in a window of the host app's scene, lets SwiftUI
    /// lay out the list over a few run loop turns, then draws the window.
    static func render(_ model: BillingModel, style: UIUserInterfaceStyle) async -> UIImage {
        let root = NavigationStack {
            MobilePlansView(entryPoint: .settings, initialPeriod: .monthly)
        }
        .environment(model)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        // The list fills in over a few layout passes; a bounded number of
        // frame-length turns, not a wait for any state.
        for _ in 0..<10 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }
}
