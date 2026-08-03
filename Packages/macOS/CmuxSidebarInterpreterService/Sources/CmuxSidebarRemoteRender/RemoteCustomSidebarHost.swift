import AppKit
import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI

/// Window-scoped storage that keeps an isolated renderer warm across mounts.
@MainActor
public final class RenderWorkerClientStore {
    public var client: RenderWorkerClient?

    public init(client: RenderWorkerClient? = nil) {
        self.client = client
    }

    /// Terminates and releases the stored worker.
    public func shutdown() {
        guard let client else { return }
        self.client = nil
        Task { await client.shutdown() }
    }
}

/// Native host that selects and mounts the worker client for one source.
@MainActor
public final class RemoteCustomSidebarHost: NSView {
    private let clientStore: RenderWorkerClientStore
    private var remoteView: RemoteCustomSidebarView?

    /// Creates a host using window-owned worker storage.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        clientStore: RenderWorkerClientStore
    ) {
        self.clientStore = clientStore
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reuses the live worker when its source matches, otherwise swaps it.
    public func update(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        let sourceKey = fileURL.standardizedFileURL.path
        let client: RenderWorkerClient
        if let existing = clientStore.client, existing.sourceKey == sourceKey {
            client = existing
        } else {
            let previous = clientStore.client
            client = RenderWorkerClient.reexecingCurrentBinary(sourceKey: sourceKey)
            clientStore.client = client
            if let previous {
                Task { await previous.shutdown() }
            }
        }

        if let remoteView, remoteView.client === client {
            remoteView.update(
                fileURL: fileURL,
                dataContext: dataContext,
                dispatch: dispatch,
                contentInsets: contentInsets
            )
            return
        }

        remoteView?.teardown()
        remoteView?.removeFromSuperview()
        let remoteView = RemoteCustomSidebarView(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            client: client
        )
        self.remoteView = remoteView
        remoteView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remoteView)
        NSLayoutConstraint.activate([
            remoteView.leadingAnchor.constraint(equalTo: leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: trailingAnchor),
            remoteView.topAnchor.constraint(equalTo: topAnchor),
            remoteView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Stops host-side streams while preserving the window-owned worker.
    public func teardown() {
        remoteView?.teardown()
        remoteView?.removeFromSuperview()
        remoteView = nil
    }
}
