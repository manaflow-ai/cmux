import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextChiefViews

/// `agents_changed` sends every row each time (p13-webui-027), so a frozen Chief views page keeps
/// only the newest event: `.latest`.
@MainActor
@Suite struct ChiefViewsPageProviderFrozenDeliveryTests {
    @Test func agentsChangedKeepsTheNewest() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ChiefViewsFrozenDelivery.\(UUID().uuidString)"))
        let provider = ChiefViewsPageProvider(host: .init(
            agents: { [] },
            fetch: { _ in Data() },
            defaults: defaults, environment: [:], now: { Date() },
            openAgent: { _, _ in },
            openURL: { _ in }))
        let subscription = try await provider.subscribe(ChiefViewsPageProvider.agentsChanged, filter: .object([:]),
                                                        context: PageCallContext(page: "cmux.chief-views")) { _ in }
        #expect(subscription.frozenDelivery == .latest)
        subscription.cancel()
    }
}
