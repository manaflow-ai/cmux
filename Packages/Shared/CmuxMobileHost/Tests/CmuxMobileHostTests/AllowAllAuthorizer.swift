import CmuxMobileHost

/// Admits every device (executor tests that are not about admission).
struct AllowAllAuthorizer: MobileDeviceAuthorizer {
    func authorize(_ request: DeviceAuthRequest) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        .success(MobileDevicePrincipal(install: "in_phone1", userID: "u_1", platform: "ios", appVersion: "1"))
    }

    func authorizeForwarded(install: String, userID: String?) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        .success(MobileDevicePrincipal(install: install, userID: userID ?? "u_1", platform: "ios", appVersion: "1"))
    }

    func revocations() async -> AsyncStream<String> { AsyncStream { _ in } }
}
