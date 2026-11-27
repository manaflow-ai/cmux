import CmuxNextRemote
import Testing

struct RemoteRelayProjectSourceTests {
    @Test(arguments: ["repo.clone", "github.repos.checkout"])
    func localCheckoutStaysOffTheRelayAllowlist(method: String) {
        let policy = RemoteRelayPolicy(allowed: [method])
        #expect(policy.decide(method: method, params: [:], owned: .init()) == .deny(.notAllowlisted(method)))
    }
}
