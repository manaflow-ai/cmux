import CmuxNextCompat
import Testing

/// Login-Keychain calls with UI off: macOS refuses an item another signature made instead of asking
/// for the login keychain password (the prompt a rebuilt DEV app showed for "cmux iPhone host identity").
@Suite(.serialized) struct LoginKeychainTests {
    @Test func turnsInteractionOffForTheBodyAndRestoresIt() {
        let keychain = LoginKeychain()
        let before = LoginKeychain.userInteractionAllowed
        let inside = keychain.withoutUI { LoginKeychain.userInteractionAllowed }
        #expect(!inside)
        #expect(LoginKeychain.userInteractionAllowed == before)
    }

    @Test func nestedGuardsRestoreOnlyWhenTheLastLeaves() {
        let keychain = LoginKeychain()
        let before = LoginKeychain.userInteractionAllowed
        let (inner, afterInner) = keychain.withoutUI {
            (keychain.withoutUI { LoginKeychain.userInteractionAllowed }, LoginKeychain.userInteractionAllowed)
        }
        #expect(!inner && !afterInner)
        #expect(LoginKeychain.userInteractionAllowed == before)
    }

    @Test func aThrowingBodyStillRestores() {
        struct Failure: Error {}
        let keychain = LoginKeychain()
        let before = LoginKeychain.userInteractionAllowed
        #expect(throws: Failure.self) { try keychain.withoutUI { () throws(Failure) in throw Failure() } }
        #expect(LoginKeychain.userInteractionAllowed == before)
    }
}
