import Foundation
import Testing
@testable import CmuxMobileModel

/// App Store screenshots shoot the mock account (`CMUX_MOBILE_MOCK_PERSONA=store`):
/// no real person's or company's name may reach them.
@Suite struct MockPersonaTests {
    @Test func defaultKeepsTheSampleDataTheTestsKnow() {
        #expect(MockPersona.current(environment: [:]) == .standard)
        #expect(MockPersona.current(environment: ["CMUX_MOBILE_MOCK_PERSONA": "other"]) == .standard)
        #expect(MockPersona.standard.mac("Mac Studio") == "Aziz's Mac Studio")
    }

    @Test func storePersonaIsFictional() {
        let store = MockPersona.current(environment: ["CMUX_MOBILE_MOCK_PERSONA": "store"])
        #expect(store == .store)
        for text in [store.userName, store.userEmail, store.owner, store.teamName, store.sideProject, store.mac("MacBook Pro")] {
            for real in [MockPersona.standard.owner, MockPersona.standard.teamName, MockPersona.standard.sideProject] {
                #expect(!text.localizedCaseInsensitiveContains(real))
            }
        }
        #expect(store.userEmail.hasSuffix("@example.com"))
    }
}
