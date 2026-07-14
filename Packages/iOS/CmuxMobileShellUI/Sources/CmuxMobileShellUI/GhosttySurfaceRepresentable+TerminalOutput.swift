#if canImport(UIKit)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import Foundation

extension GhosttySurfaceRepresentable.Coordinator {
    @MainActor
    func makeTerminalOutputTask(
        store: CMUXMobileShellStore,
        surfaceView: GhosttySurfaceView,
        surfaceID: String
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak surfaceView, weak store] in
            guard let store else { return }
            for await chunk in store.authoritativeTerminalOutputStream(surfaceID: surfaceID) {
                guard !Task.isCancelled, let self, let surfaceView else { return }
                if authoritativeStreamToken != chunk.streamToken {
                    authoritativeStreamToken = chunk.streamToken
                    surfaceView.resetAuthoritativeRenderGrid(surfaceID: surfaceID)
                }
                guard await applyViewportPolicy(
                    chunk,
                    to: surfaceView,
                    store: store,
                    surfaceID: surfaceID
                ) else { continue }
                guard await presentOutput(
                    chunk,
                    on: surfaceView,
                    store: store,
                    surfaceID: surfaceID
                ) else { continue }
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
            }
        }
    }

    @MainActor
    private func applyViewportPolicy(
        _ chunk: MobileTerminalOutputChunk,
        to surfaceView: GhosttySurfaceView,
        store: CMUXMobileShellStore,
        surfaceID: String
    ) async -> Bool {
        let hasVisualPayload = chunk.renderGrid != nil || !chunk.data.isEmpty
        let applied: Bool
        switch chunk.viewportPolicy {
        case .natural:
            activeViewportPolicy = .natural
            if hasVisualPayload {
                applied = await surfaceView.useNaturalViewSizeAndWait()
            } else {
                surfaceView.useNaturalViewSize()
                applied = true
            }
        case .remoteGrid(let columns, let rows):
            activeViewportPolicy = .remoteGrid(columns: columns, rows: rows)
            if hasVisualPayload {
                applied = await surfaceView.applyViewSizeAndWait(cols: columns, rows: rows)
            } else {
                surfaceView.applyViewSize(cols: columns, rows: rows)
                applied = true
            }
        case nil:
            applied = true
        }
        if !applied {
            store.terminalOutputDidReset(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
        }
        return applied
    }

    @MainActor
    private func presentOutput(
        _ chunk: MobileTerminalOutputChunk,
        on surfaceView: GhosttySurfaceView,
        store: CMUXMobileShellStore,
        surfaceID: String
    ) async -> Bool {
        if let renderGrid = chunk.renderGrid {
            guard surfaceView.presentAuthoritativeRenderGrid(renderGrid) != .needsFullSnapshot else {
                store.terminalOutputDidReset(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
                return false
            }
            return true
        }
        guard !chunk.data.isEmpty else { return true }
        surfaceView.useRawTerminalRenderer()
        let applied = await surfaceView.processOutputAndWait(chunk.data)
        if !applied {
            store.terminalOutputDidReset(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
        }
        return applied
    }
}
#endif
