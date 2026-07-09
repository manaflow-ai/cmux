internal import Foundation
@_spi(CmuxHostTransport) internal import CmuxExtensionKit

/// `NSXPCConnection` exported object that answers an extension's snapshot and
/// action requests on the host side.
///
/// Owned by ``CMUXSidebarExtensionHostXPC``; every reply hops to `@MainActor`,
/// rejects requests that arrive on a superseded connection generation, and
/// returns the injected `staleConnection` message in that case. The message is
/// resolved app-side (see ``CMUXSidebarExtensionHostXPCStrings``) so the app
/// bundle's localized catalog is used.
@MainActor
final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    var snapshotProvider: @MainActor @Sendable () -> CmuxSidebarSnapshot
    var actionHandler: @MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult
    var onAcceptedAction: @MainActor @Sendable () -> Void
    var isCurrentGeneration: @MainActor @Sendable () -> Bool
    private let staleConnection: String

    init(
        snapshotProvider: @escaping @MainActor @Sendable () -> CmuxSidebarSnapshot,
        actionHandler: @escaping @MainActor @Sendable (CmuxSidebarAction) -> CmuxSidebarActionResult,
        onAcceptedAction: @escaping @MainActor @Sendable () -> Void,
        isCurrentGeneration: @escaping @MainActor @Sendable () -> Bool,
        staleConnection: String
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.onAcceptedAction = onAcceptedAction
        self.isCurrentGeneration = isCurrentGeneration
        self.staleConnection = staleConnection
    }

    nonisolated func requestSidebarSnapshot(reply: @escaping @Sendable (NSData?, NSString?) -> Void) {
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

    nonisolated func performSidebarAction(_ payload: NSData, reply: @escaping @Sendable (NSData?, NSString?) -> Void) {
        // Copy the payload to a Sendable `Data` value before hopping to the main
        // actor so the non-Sendable `NSData` is not transferred across isolation
        // domains; the decoder reads the same bytes.
        let payloadData = payload as Data
        Task { @MainActor in
            guard isCurrentGeneration() else {
                reply(nil, staleConnection as NSString)
                return
            }
            do {
                let action = try CmuxSidebarXPCCodec.decodeAction(payloadData as NSData)
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
