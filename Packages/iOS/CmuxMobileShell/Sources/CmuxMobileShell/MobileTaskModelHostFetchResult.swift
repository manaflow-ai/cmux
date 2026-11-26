internal import CmuxMobileShellModel

/// A host catalog paired with the client identity validated for its response.
struct MobileTaskModelHostFetchResult: Sendable {
    let result: MobileTaskModelListResult
    let connectionIdentity: String
}
