import CmuxSwiftRender
import Foundation
import Testing

struct ButtonActionCodingTests {
    @Test func userGestureFlagRoundTrips() throws {
        let action = ButtonAction(commands: [.log("x")], isUserGesture: false)
        let decoded = try JSONDecoder().decode(ButtonAction.self, from: JSONEncoder().encode(action))
        #expect(decoded == action)
        #expect(decoded.isUserGesture == false)
    }

    /// An action encoded without the flag (the Swift dialect's buttons before
    /// the flag existed) is a click.
    @Test func missingUserGestureFlagDecodesAsAClick() throws {
        let json = Data(#"{"commands":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ButtonAction.self, from: json)
        #expect(decoded == ButtonAction(commands: []))
        #expect(decoded.isUserGesture)
    }
}
