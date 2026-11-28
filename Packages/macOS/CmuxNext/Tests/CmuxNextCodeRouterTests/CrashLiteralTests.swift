import Foundation
import Testing
@testable import CmuxNextCodeRouter

/// Crash program: the local server defaults are literals that must parse.
@Suite struct CodeRouterCrashLiteralTests {
    @Test func localServerDefaultsParse() {
        #expect(ProviderDetector.ollamaDefault.absoluteString == "http://127.0.0.1:11434")
        #expect(ProviderDetector.lmStudioDefault.absoluteString == "http://127.0.0.1:1234")
        #expect(KeychainProviderKeyStore.service(bundleID: "") == "com.cmuxterm.app.ai-provider-keys")
    }
}
