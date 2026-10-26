@testable import CmuxNextApp
import Testing

/// `AppServices.init` neither starts Cloud nor the feed handoff (p08-startup task 020): both wait for the
/// launch's Cloud post (`CloudStartPost`) or an earlier need such as a sign-in callback.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudOnDemandTests {
    @Test func servicesInitStartsNeitherCloudNorTheFeedHandoff() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cloudContext == nil, "Cloud starts from the launch's post, not from init")
        #expect(services.notifications.feedDriver == nil, "the feed handoff waits for the Cloud start")
        // A window's registry context reads the auth only, and starts nothing.
        services.cloudContextDidChange()
        #expect(services.cloudContext == nil)
        // Quit before Cloud started stops nothing and builds nothing.
        services.stopCloud()
        #expect(services.cloudContext == nil)
    }
}
