#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileTerminal
import Foundation
import UIKit

extension GhosttySurfaceRepresentable.Coordinator {
    func attachSemanticScene(surfaceView: GhosttySurfaceView) {
        surfaceView.semanticSceneGeometryDidChange = { [weak self] geometry in
            self?.restartSemanticScene(geometry: geometry)
        }
        surfaceView.semanticSceneAnimationFrameRequested = { [weak self] in
            self?.renderSemanticSceneAnimationFrame()
        }
        surfaceView.semanticSceneConfigurationDidChange = { [weak self, weak surfaceView] in
            guard let self, let geometry = self.semanticSceneGeometry else { return }
            self.restartSemanticScene(geometry: geometry, force: true)
            surfaceView?.setNeedsLayout()
        }
        surfaceView.semanticSceneVisibilityDidChange = { [weak self] active in
            self?.setSemanticScenePresentationActive(active)
        }
        guard let store else { return }
        let surfaceID = surfaceID
        liveFontTask = Task { @MainActor [weak self, weak store] in
            guard let store else { return }
            for await points in store.terminalLiveFontStream(surfaceID: surfaceID) {
                guard !Task.isCancelled,
                      let self else { continue }
                self.surfaceView?.setLiveFontSize(points)
            }
        }
        surfaceView.setNeedsLayout()
        setSemanticScenePresentationActive(
            surfaceView.window != nil && UIApplication.shared.applicationState == .active
        )
    }

    func restartSemanticScene(
        geometry: GhosttySemanticSceneGeometry,
        force: Bool = false
    ) {
        guard semanticScenePresentationActive,
              let store, let surfaceView,
              force || geometry != semanticSceneGeometry || semanticSceneToken == nil else {
            return
        }
        semanticSceneGeometry = geometry
        semanticSceneGeneration &+= 1
        if semanticSceneGeneration == 0 {
            semanticSceneGeneration = 1
        }
        let generation = semanticSceneGeneration
        let priorToken = semanticSceneToken
        let priorRenderer = semanticSceneRenderer
        semanticSceneToken = nil
        semanticSceneAnimationInFlight = false
        surfaceView.setSemanticSceneAnimationEnabled(false)

        let renderer: GhosttySemanticSceneRenderer
        do {
            renderer = try GhosttySemanticSceneRenderer(
                presentationLayer: surfaceView.semanticScenePresentationLayer,
                fontSizeOverride: surfaceView.semanticSceneFontSizeOverride
            )
        } catch {
            semanticSceneRecoveryAttempts += 1
            if semanticSceneRecoveryAttempts < 3 {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.restartSemanticScene(geometry: geometry, force: true)
                }
            } else {
                store.disableTerminalSemanticScenesForCurrentConnection()
            }
            return
        }
        semanticSceneRenderer = renderer
        semanticSceneRestartTask?.cancel()
        let pendingTeardown = semanticSceneTeardownTask
        let surfaceID = surfaceID
        let presentationID = semanticScenePresentationID
        semanticSceneRestartTask = Task { @MainActor [weak self, weak store] in
            // Backgrounding and a fast foreground can overlap. Wait for the
            // retired renderer's last queued Metal copy before admitting a new
            // generation to the shared presentation layer.
            await pendingTeardown?.value
            if let priorToken {
                await store?.deactivateTerminalScene(
                    surfaceID: surfaceID,
                    token: priorToken
                )
            }
            await priorRenderer?.close()
            guard !Task.isCancelled,
                  let self,
                  let store,
                  self.semanticSceneGeneration == generation,
                  self.semanticSceneRenderer === renderer else {
                await renderer.close()
                return
            }

            let request = MobileTerminalSceneRequest(
                surfaceID: surfaceID,
                presentationID: presentationID,
                presentationGeneration: generation,
                width: geometry.width,
                height: geometry.height,
                contentScale: geometry.contentScale
            )
            do {
                let token = try await store.activateTerminalScene(
                    request,
                    consume: { [weak self, renderer] envelope in
                        let metrics = try await renderer.consume(envelope)
                        switch envelope {
                        case .configuration:
                            guard let metrics else { return false }
                            await MainActor.run { [weak self] in
                                guard let self,
                                      self.semanticSceneGeneration == generation,
                                      self.semanticSceneRenderer === renderer else { return }
                                self.surfaceView?.applySemanticSceneMetrics(metrics)
                            }
                            return false
                        case .scene:
                            return false
                        case let .accessibility(accessibility):
                            guard let metrics else { return false }
                            let shouldAnimate = try await renderer.shouldAnimate(visible: true)
                            return await MainActor.run { [weak self] in
                                guard let self,
                                      self.semanticSceneGeneration == generation,
                                      self.semanticSceneRenderer === renderer else { return false }
                                self.semanticSceneRecoveryAttempts = 0
                                self.surfaceView?.applySemanticSceneMetrics(metrics)
                                self.surfaceView?.applySemanticSceneAccessibility(accessibility)
                                self.surfaceView?.setSemanticSceneAnimationEnabled(shouldAnimate)
                                return true
                            }
                        }
                    },
                    finished: { [weak self] token, termination in
                        await MainActor.run { [weak self] in
                            self?.semanticSceneDidFinish(
                                token: token,
                                generation: generation,
                                geometry: geometry,
                                termination: termination
                            )
                        }
                    }
                )
                guard self.semanticSceneGeneration == generation,
                      self.semanticSceneRenderer === renderer else {
                    await store.deactivateTerminalScene(
                        surfaceID: surfaceID,
                        token: token
                    )
                    await renderer.close()
                    return
                }
                self.semanticSceneToken = token
            } catch is CancellationError {
                await renderer.close()
            } catch {
                guard self.semanticSceneGeneration == generation else {
                    await renderer.close()
                    return
                }
                self.semanticSceneRecoveryAttempts += 1
                await renderer.close()
                if self.semanticSceneRecoveryAttempts < 3 {
                    self.restartSemanticScene(geometry: geometry, force: true)
                } else {
                    store.disableTerminalSemanticScenesForCurrentConnection()
                }
            }
        }
    }

    func setSemanticScenePresentationActive(_ active: Bool) {
        guard semanticScenePresentationActive != active else { return }
        semanticScenePresentationActive = active
        if active {
            if let geometry = semanticSceneGeometry {
                restartSemanticScene(geometry: geometry, force: true)
            }
        } else {
            stopSemanticScene(resetGeometry: true)
        }
    }

    private func stopSemanticScene(resetGeometry: Bool) {
        semanticSceneGeneration &+= 1
        if semanticSceneGeneration == 0 {
            semanticSceneGeneration = 1
        }
        semanticSceneRestartTask?.cancel()
        semanticSceneRestartTask = nil
        let token = semanticSceneToken
        semanticSceneToken = nil
        let renderer = semanticSceneRenderer
        semanticSceneRenderer = nil
        semanticSceneAnimationInFlight = false
        surfaceView?.setSemanticSceneAnimationEnabled(false)
        if resetGeometry {
            semanticSceneGeometry = nil
        }
        let store = store
        let surfaceID = surfaceID
        if token != nil || renderer != nil {
            let precedingTeardown = semanticSceneTeardownTask
            semanticSceneTeardownTask = Task {
                await precedingTeardown?.value
                if let token {
                    await store?.deactivateTerminalScene(
                        surfaceID: surfaceID,
                        token: token
                    )
                }
                await renderer?.close()
            }
        }
    }

    func semanticSceneDidFinish(
        token: UUID,
        generation: UInt64,
        geometry: GhosttySemanticSceneGeometry,
        termination _: MobileTerminalSceneTermination
    ) {
        guard semanticScenePresentationActive,
              semanticSceneGeneration == generation else { return }
        if semanticSceneToken == token {
            semanticSceneToken = nil
        }
        semanticSceneRecoveryAttempts += 1
        guard semanticSceneRecoveryAttempts < 3 else {
            store?.disableTerminalSemanticScenesForCurrentConnection()
            return
        }
        restartSemanticScene(geometry: geometry, force: true)
    }

    func renderSemanticSceneAnimationFrame() {
        guard semanticScenePresentationActive,
              !semanticSceneAnimationInFlight,
              let renderer = semanticSceneRenderer else { return }
        semanticSceneAnimationInFlight = true
        let generation = semanticSceneGeneration
        Task { @MainActor [weak self] in
            do {
                try await renderer.renderAnimationFrame()
                let shouldContinue = try await renderer.shouldAnimate(visible: true)
                guard let self,
                      self.semanticSceneGeneration == generation,
                      self.semanticSceneRenderer === renderer else { return }
                self.semanticSceneAnimationInFlight = false
                self.surfaceView?.setSemanticSceneAnimationEnabled(shouldContinue)
            } catch {
                guard let self,
                      self.semanticSceneGeneration == generation else { return }
                self.semanticSceneAnimationInFlight = false
                if let geometry = self.semanticSceneGeometry {
                    self.restartSemanticScene(geometry: geometry, force: true)
                }
            }
        }
    }

    func detachSemanticScene() {
        semanticScenePresentationActive = false
        surfaceView?.semanticSceneGeometryDidChange = nil
        surfaceView?.semanticSceneAnimationFrameRequested = nil
        surfaceView?.semanticSceneConfigurationDidChange = nil
        surfaceView?.semanticSceneVisibilityDidChange = nil
        stopSemanticScene(resetGeometry: true)
    }
}
#endif
