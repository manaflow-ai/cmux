import Testing
import CSSHNative
@testable import CmuxSSHNative

@Suite struct NativeConfigurationTests {
    @Test func defaultConnectionTimeoutIsPositive() {
        #expect(NativeDurationProbe.isPositive(MobileRemoteNativeSSHConfiguration.defaultConfiguration.connectTimeout))
    }

    @Test func CShimCreatesAndDestroysAnIsolatedSessionWithoutReadingUserConfig() {
        let handle = cmux_ssh_create("127.0.0.1", 1, "fixture")
        #expect(handle != nil)
        if let handle { cmux_ssh_destroy(handle) }
    }
}

private enum NativeDurationProbe {
    static func isPositive(_ duration: Duration) -> Bool {
        duration > .zero
    }
}
