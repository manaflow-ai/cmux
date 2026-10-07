/// The workspace directories a device may reach, asked per request so a
/// closed workspace stops being reachable at once. The app adapter answers
/// from the workspace store; the inbox is added by the policy itself.
public protocol MobileFileRootsProvider: Sendable {
    func roots(for principal: MobileDevicePrincipal) async -> [MobileFileRoot]
}
