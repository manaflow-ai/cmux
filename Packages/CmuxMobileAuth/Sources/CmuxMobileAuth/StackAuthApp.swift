import Foundation
import StackAuth

enum StackAuthApp {
    #if DEBUG && targetEnvironment(simulator)
    private static let tokenStore: TokenStoreInit = .memory
    #else
    private static let tokenStore: TokenStoreInit = .keychain
    #endif

    static let shared = StackClientApp(
        projectId: AppEnvironment.current.stackAuthProjectId,
        publishableClientKey: AppEnvironment.current.stackAuthPublishableKey,
        tokenStore: tokenStore
    )
}
