public import Foundation
@_spi(CmuxHostTransport) public import CmuxExtensionKit

/// `NSXPCConnection` exported object that answers an extension's snapshot and
/// action requests on the host side.
///
/// Owned by ``CMUXSidebarExtensionHostXPC``; every reply hops to `@MainActor`,
/// rejects requests that arrive on a superseded connection generation, and
/// returns the injected `staleConnection` message in that case. The message is
/// resolved app-side (see ``CMUXSidebarExtensionHostXPCStrings``) so the app
/// bundle's localized catalog is used.
final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    @MainActor var snapshotProvider: () -> CmuxSidebarSnapshot
    @MainActor var actionHandler: (CmuxSidebarAction) -> CmuxSidebarActionResult
    @MainActor var onAcceptedAction: () -> Void
    @MainActor var isCurrentGeneration: () -> Bool
    private let staleConnection: String

    @MainActor
    init(
        snapshotProvider: @escaping @MainActor () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onAcceptedAction: @escaping @MainActor () -> Void,
        isCurrentGeneration: @escaping @MainActor () -> Bool,
        staleConnection: String
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.onAcceptedAction = onAcceptedAction
        self.isCurrentGeneration = isCurrentGeneration
        self.staleConnection = staleConnection
    }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, staleConnection as NSString)
                return
            }
            do {
                reply(try CmuxSidebarXPCCodec.encodeSnapshot(snapshotProvider()), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, staleConnection as NSString)
                return
            }
            do {
                let action = try CmuxSidebarXPCCodec.decodeAction(payload)
                let result = actionHandler(action)
                reply(try CmuxSidebarXPCCodec.encodeActionResult(result), nil)
                if result.accepted {
                    onAcceptedAction()
                }
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }
}
