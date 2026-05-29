import CMUXExtensionClient
import CmuxExtensionKit
import ExtensionFoundation
import SwiftUI

struct CMUXInstalledExtensionSidebarHostView: View {
    var snapshotProvider: @MainActor () -> CMUXSidebarSnapshot
    var actionHandler: @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult

    @State private var identity: AppExtensionIdentity?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var xpcHost = CMUXSidebarExtensionHostXPC()

    var body: some View {
        Group {
            if let identity {
                CMUXSidebarExtensionHostView(
                    identity: identity,
                    onConnection: { connection in
                        xpcHost.attach(
                            connection: connection,
                            snapshotProvider: snapshotProvider,
                            actionHandler: actionHandler
                        )
                    },
                    onDeactivation: { error in
                        xpcHost.invalidate()
                        errorText = error?.localizedDescription
                    }
                )
                    .accessibilityIdentifier("CMUXExtensionSidebarHostView")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "sidebar.extensions.loading", defaultValue: "Loading sidebar extensions"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(errorText ?? String(
                            localized: "sidebar.extensions.empty.detail",
                            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
                        ))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, SidebarWorkspaceScrollInsets.workspaceList.top + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
            }
        }
        .task {
            xpcHost.update(snapshotProvider: snapshotProvider, actionHandler: actionHandler)
            await loadExtension()
        }
        .onChange(of: snapshotProvider().sequence) { _, _ in
            xpcHost.sendSnapshotDidChange()
        }
    }

    private func loadExtension() async {
        isLoading = true
        errorText = nil
        do {
            let update = try await Task.detached(priority: .userInitiated) {
                var identities = try AppExtensionIdentity.matching(
                    appExtensionPointIDs: CMUXSidebarExtensionPoint.identifier
                )
                .makeAsyncIterator()
                return await identities.next() ?? []
            }.value
            identity = update.sorted { $0.localizedName < $1.localizedName }.first
            isLoading = false
        } catch {
            identity = nil
            isLoading = false
            errorText = String(
                localized: "sidebar.extensions.error",
                defaultValue: "CMUX could not load sidebar extensions."
            )
        }
    }
}

@MainActor
private final class CMUXSidebarExtensionHostXPC {
    private var connection: NSXPCConnection?
    private var extensionProxy: CMUXSidebarExtensionXPC?
    private var exportedObject: CMUXSidebarHostXPCObject?
    private var snapshotProvider: (() -> CMUXSidebarSnapshot)?
    private var actionHandler: ((CMUXSidebarAction) -> CMUXExtensionActionResult)?

    func update(
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        exportedObject?.snapshotProvider = snapshotProvider
        exportedObject?.actionHandler = actionHandler
    }

    func attach(
        connection: NSXPCConnection,
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult
    ) {
        invalidate()
        let exportedObject = CMUXSidebarHostXPCObject(
            snapshotProvider: snapshotProvider,
            actionHandler: actionHandler
        )
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.clearConnection()
            }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.clearProxy()
            }
        }
        self.exportedObject = exportedObject
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.connection = connection
        self.extensionProxy = connection.remoteObjectProxy as? CMUXSidebarExtensionXPC
        connection.resume()
        sendSnapshotDidChange()
    }

    func sendSnapshotDidChange() {
        guard let extensionProxy, let snapshotProvider else { return }
        do {
            extensionProxy.sidebarSnapshotDidChange(try CMUXSidebarXPCCodec.encodeSnapshot(snapshotProvider()))
        } catch {
#if DEBUG
            cmuxDebugLog("extension.sidebar.xpc.snapshot.encode.failed error=\(error.localizedDescription)")
#endif
        }
    }

    func invalidate() {
        connection?.invalidate()
        clearConnection()
    }

    private func clearProxy() {
        extensionProxy = nil
    }

    private func clearConnection() {
        connection = nil
        extensionProxy = nil
        exportedObject = nil
    }
}

private final class CMUXSidebarHostXPCObject: NSObject, CMUXSidebarHostXPC {
    @MainActor var snapshotProvider: () -> CMUXSidebarSnapshot
    @MainActor var actionHandler: (CMUXSidebarAction) -> CMUXExtensionActionResult

    @MainActor
    init(
        snapshotProvider: @escaping @MainActor () -> CMUXSidebarSnapshot,
        actionHandler: @escaping @MainActor (CMUXSidebarAction) -> CMUXExtensionActionResult
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
    }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            do {
                reply(try CMUXSidebarXPCCodec.encodeSnapshot(snapshotProvider()), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        Task { @MainActor in
            do {
                let action = try CMUXSidebarXPCCodec.decodeAction(payload)
                let result = actionHandler(action)
                reply(try CMUXSidebarXPCCodec.encodeActionResult(result), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }
}
