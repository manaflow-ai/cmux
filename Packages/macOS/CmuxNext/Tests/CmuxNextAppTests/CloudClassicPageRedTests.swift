import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import Foundation
import Testing

/// Red half of the classic-link Cloud page fix, on the base: the page provider the app builds
/// (`account.appOps`) answers auth.status on the classic link with no daemon relay.
@MainActor @Suite(.serialized)
struct CloudClassicPageRedTests {
    @Test func theClassicLinkPageAnswersWithoutTheRelay() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cloud.configuration.linkSource == .legacy)
        let provider = CloudPageProvider(op: services.cloud.appOps)
        let answer = try await provider.call("cmux.cloud.auth.status", params: .object([:]),
                                             context: PageCallContext(page: PageDescriptor.cloud.id))
        #expect(answer["signedIn"]?.boolValue == services.cloud.isSignedIn)
    }
}
