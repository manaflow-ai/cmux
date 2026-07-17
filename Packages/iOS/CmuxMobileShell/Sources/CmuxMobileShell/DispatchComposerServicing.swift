public import Foundation

/// The narrow store surface the Dispatch composer depends on.
///
/// `MobileShellComposite` is the production conformer; previews and tests use
/// lightweight stubs so the composer UI renders without a paired Mac.
@MainActor
public protocol DispatchComposerServicing: AnyObject {
    /// Display name of the connected Mac, for the work-order header.
    var dispatchHostName: String? { get }
    /// Whether a launch attempted right now could reach the Mac.
    var dispatchIsConnected: Bool { get }
    /// Stable per-Mac key for drafts and serial counters.
    var dispatchMacKey: String { get }

    func dispatchCatalog() async throws -> DispatchCatalog
    func dispatchFSList(path: String, includeHidden: Bool) async throws -> DispatchFSList
    func dispatchFSSearch(query: String) async throws -> DispatchFSSearch
    func dispatchLaunch(directory: String, agentID: String, prompt: String) async -> Result<Void, DispatchLaunchFailure>
}
