import CmuxAuthRuntime

/// The result of a host-status request together with the account snapshot that
/// authenticated it. Keeping the snapshot beside the result prevents a Mac
/// sign-out/account switch between verification and paired-phone persistence.
struct MobileHostStatusResolution: Sendable {
    let result: MobileHostRPCResult
    let authenticatedSessionIdentity: AuthenticatedSessionIdentity?
}
