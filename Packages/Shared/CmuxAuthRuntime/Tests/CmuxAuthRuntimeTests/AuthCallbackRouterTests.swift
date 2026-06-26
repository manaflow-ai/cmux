import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthCallbackRouterTests {
    @Test func iOSCallbackSchemesMustBeInjectedPerChannel() {
        let macRouter = AuthCallbackRouter()
        #expect(macRouter.isAuthCallbackURL(URL(string: "cmux://auth-callback")!))
        #expect(macRouter.isAuthCallbackURL(URL(string: "cmux-nightly://auth-callback")!))
        #expect(macRouter.isAuthCallbackURL(URL(string: "cmux-dev://auth-callback")!))
        #expect(!macRouter.isAuthCallbackURL(URL(string: "cmux-ios://auth-callback")!))
        #expect(!macRouter.isAuthCallbackURL(URL(string: "cmux-ios-beta://auth-callback")!))

        let appStoreRouter = AuthCallbackRouter(extraAllowedScheme: "cmux-ios")
        #expect(appStoreRouter.isAuthCallbackURL(URL(string: "cmux-ios://auth-callback")!))
        #expect(!appStoreRouter.isAuthCallbackURL(URL(string: "cmux-ios-beta://auth-callback")!))

        let testFlightRouter = AuthCallbackRouter(extraAllowedScheme: "cmux-ios-beta")
        #expect(testFlightRouter.isAuthCallbackURL(URL(string: "cmux-ios-beta://auth-callback")!))
        #expect(!testFlightRouter.isAuthCallbackURL(URL(string: "cmux-ios://auth-callback")!))
    }
}
