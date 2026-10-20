import CMUXMobileCore
import CryptoKit
public import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

public extension MobileShellComposite {
    /// The durable account/Mac/build partition. It stays stable during an
    /// ordinary reconnect and changes when the user changes account or Mac.
    var conversationScopeID: String? {
        guard let accountID = identityProvider?.currentUserID, !accountID.isEmpty,
              let hostID = foregroundMacDeviceID ?? recoveryTargetMacDeviceID ?? connectedMacDeviceID,
              !hostID.isEmpty, !hostID.hasPrefix("manual-") else { return nil }
        let tag = connectionState == .connected ? activeMacInstanceTag : recoveryTargetInstanceTag
        let parts = [accountID, cmxCanonicalDeviceID(hostID), tag ?? "default", Bundle.main.bundleIdentifier ?? "cmux"]
        // Length delimiters avoid ambiguous concatenation. No account or host
        // value becomes a filename or diagnostic label.
        let material = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The native task picker only offers workspaces served by this connection.
    var conversationWorkspaces: [MobileWorkspacePreview] {
        workspaces.filter { workspace in
            guard let owner = workspace.macDeviceID, !owner.isEmpty,
                  let host = foregroundMacDeviceID ?? recoveryTargetMacDeviceID ?? connectedMacDeviceID else { return false }
            let tag = connectionState == .connected ? activeMacInstanceTag : recoveryTargetInstanceTag
            return cmxCanonicalDeviceID(owner) == cmxCanonicalDeviceID(host)
                && macInstanceTagAuthority.sameStoredAuthority(workspace.macInstanceTag, tag)
        }
    }

    /// Changes when the native task UI must replace its transport or targets.
    var conversationConnectionKey: String {
        ([conversationScopeID ?? "signed-out", remoteClient?.instanceID ?? "offline",
          connectionState == .connected ? "connected" : "disconnected"]
            + conversationWorkspaces.map { $0.rpcWorkspaceID.rawValue }.sorted())
            .joined(separator: "|")
    }

    /// Resolves a fresh transport around the same durable store. No provider
    /// work is started and no uncertain command is replayed by this method.
    func makeConversationClient() throws -> MobileConversationClient? {
        guard connectionState == .connected, let remoteClient, let scope = conversationScopeID else { return nil }
        let workspaceIDs = Set(conversationWorkspaces.map { $0.rpcWorkspaceID.rawValue })
        guard !workspaceIDs.isEmpty else { return nil }
        let storage: MobileConversationStorage
        if let cached = conversationStorage[scope] {
            storage = cached
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            storage = try MobileConversationStorage(
                fileURL: base.appendingPathComponent("NativeConversations", isDirectory: true)
                    .appendingPathComponent(scope, isDirectory: true).appendingPathComponent("commands.json")
            )
            conversationStorage[scope] = storage
        }
        return MobileConversationClient(connection: remoteClient, workspaceIDs: workspaceIDs, storage: storage)
    }
}
