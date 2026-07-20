#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import Foundation

extension GhosttySurfaceRepresentable.Coordinator {
    @MainActor
    func makeTerminalOutputTask(
        store: CMUXMobileShellStore,
        surfaceView: GhosttySurfaceView,
        surfaceID: String,
        viewportOwnershipRelease: Task<Void, Never>? = nil
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak surfaceView, weak store] in
            guard let store else { return }
            // A previous raw-render attachment may still pin the Mac PTY to
            // phone geometry. Await its explicit clear before cold replay so
            // the first direct frame is producer-native too.
            await viewportOwnershipRelease?.value
            for await chunk in store.authoritativeTerminalOutputStream(surfaceID: surfaceID) {
                guard !Task.isCancelled, let self, let surfaceView else { return }
                if authoritativeStreamToken != chunk.streamToken {
                    authoritativeStreamToken = chunk.streamToken
                    if Self.shouldBeginReplayForNewStream(
                        authoritativeGridEnabled: store.supportsAuthoritativeTerminalGrid
                    ) {
                        surfaceView.beginAuthoritativeRenderGridReplay(surfaceID: surfaceID)
                    }
                }
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
        if let chunkConfigTheme = chunk.terminalConfigTheme,
           chunkConfigTheme != store.terminalConfigTheme(for: surfaceID) {
            return reject(chunk, store: store, surfaceID: surfaceID)
        }
        if let renderGrid = chunk.renderGrid {
            return await presentAuthoritativeGrid(
                renderGrid,
                chunk: chunk,
                on: surfaceView,
                store: store,
                surfaceID: surfaceID
            )
        }
        return await presentRawOutput(
            chunk,
            on: surfaceView,
            store: store,
            surfaceID: surfaceID
        )
    }

    @MainActor
    private func presentAuthoritativeGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        chunk: MobileTerminalOutputChunk,
        on surfaceView: GhosttySurfaceView,
        store: CMUXMobileShellStore,
        surfaceID: String
    ) async -> Bool {
        let admission = surfaceView.classifyAuthoritativeRenderGrid(renderGrid)
        if admission == .ignoredStale { return true }
        guard admission.allowsViewportMutation else {
            return reject(chunk, store: store, surfaceID: surfaceID)
        }
        surfaceView.prepareForAuthoritativeRenderGridPresentation()
        guard await applyViewportPolicy(
            chunk,
            to: surfaceView,
            store: store,
            surfaceID: surfaceID
        ) else { return false }
        guard surfaceView.presentAuthoritativeRenderGrid(renderGrid) == .presented else {
            return reject(chunk, store: store, surfaceID: surfaceID)
        }
        return true
    }

    @MainActor
    private func presentRawOutput(
        _ chunk: MobileTerminalOutputChunk,
        on surfaceView: GhosttySurfaceView,
        store: CMUXMobileShellStore,
        surfaceID: String
    ) async -> Bool {
        let authoritativeGridEnabled = store.supportsAuthoritativeTerminalGrid
        guard Self.acceptsRawChunk(
            authoritativeGridEnabled: authoritativeGridEnabled,
            dataIsEmpty: chunk.data.isEmpty
        ) else {
            return reject(chunk, store: store, surfaceID: surfaceID)
        }
        if Self.shouldUseRawRenderer(
            authoritativeGridEnabled: authoritativeGridEnabled,
            hasAuthoritativeGrid: chunk.renderGrid != nil
        ) {
            // Restore raw presentation even for a viewport-only chunk. A new
            // ordinary stream token must never leave Ghostty hidden while it
            // waits for the first non-empty byte chunk.
            surfaceView.useRawTerminalRenderer()
        }
        if chunk.data.isEmpty, chunk.terminalConfigTheme == nil {
            return await applyViewportPolicy(
                chunk,
                to: surfaceView,
                store: store,
                surfaceID: surfaceID
            )
        }
        guard await applyViewportPolicy(
            chunk,
            to: surfaceView,
            store: store,
            surfaceID: surfaceID
        ) else { return false }
        let applied = await surfaceView.processOutputAndWait(
            chunk.data,
            terminalConfigTheme: chunk.terminalConfigTheme
        )
        if !applied {
            store.terminalOutputDidReset(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
        }
        return applied
    }

    @MainActor
    private func reject(
        _ chunk: MobileTerminalOutputChunk,
        store: CMUXMobileShellStore,
        surfaceID: String
    ) -> Bool {
        store.terminalOutputDidReset(
            surfaceID: surfaceID,
            streamToken: chunk.streamToken
        )
        return false
    }
}
#endif
