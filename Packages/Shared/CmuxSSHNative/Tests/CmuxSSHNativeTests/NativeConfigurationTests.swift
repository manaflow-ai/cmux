import Testing
@testable import CmuxSSHNative

@Suite struct NativeConfigurationTests {
    @Test func defaultConnectionTimeoutIsPositive() {
        #expect(NativeDurationProbe.isPositive(MobileRemoteNativeSSHConfiguration.defaultConfiguration.connectTimeout))
    }
}

private enum NativeDurationProbe {
    static func isPositive(_ duration: Duration) -> Bool {
        duration > .zero
    }
}
