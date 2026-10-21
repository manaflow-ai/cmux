import CmuxNextMobile
import Foundation
@testable import CmuxNextMobileHost
import Testing

/// The one phone list (Settings > Mobile) has one owner for its user: the iPhone host's account.
/// A team switch keeps the user's list, another user starts with an empty one, and a sign-out lets no phone
/// in and forgets that user's phones. The Iroh link only reads it (PhoneAdmissionTests).
@MainActor
struct PhoneListOwnerTests {
    private static func account(_ user: String, team: String) -> IPhoneHostService.Account {
        IPhoneHostService.Account(userID: user, teamID: team, teamName: nil, email: nil)
    }

    @Test func theIPhoneHostsAccountDecidesWhoseListItIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-list-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = IPhoneHostService()
        var dependencies = IPhoneHostChiefTests.dependencies(chief: nil)
        dependencies.stateDirectory = directory
        host.dependencies = dependencies
        host.accountChanged(Self.account("u", team: "team-a"))
        #expect(host.pairedStore.current?.userID == "u")
        let key = String(repeating: "ab", count: 32)
        try host.pairedStore.change {
            $0.approve(MobileHostPairRequest(phoneDeviceID: key, name: "p", identityKey: key, approvalKey: "", transport: .iroh), at: Date())
        }
        host.accountChanged(Self.account("u", team: "personal-u"))
        #expect(host.pairedStore.current?.devices.map(\.id) == [key])
        host.accountChanged(Self.account("v", team: "personal-v"))
        #expect(host.pairedStore.current?.userID == "v")
        #expect(host.pairedStore.current?.devices.isEmpty == true)
        host.accountChanged(nil)
        #expect(host.pairedStore.current == nil)
        // The list is one user's: u's phones went when v signed in, so u starts empty and is asked again.
        host.accountChanged(Self.account("u", team: "personal-u"))
        #expect(host.pairedStore.current?.userID == "u")
        #expect(host.pairedStore.current?.devices.isEmpty == true)
    }
}
