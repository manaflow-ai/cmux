#if DEBUG
import CmuxMobileDiagnostics
import Foundation

extension MobileShellComposite {
    func startLatencyProbeAutoNavigationIfNeeded() {
        guard connectionState == .connected,
              latencyProbeAutoNavigationTask == nil,
              MobileLatencyProbe.hasUnclaimedConfiguration,
              terminalOutputStreamTokensBySurfaceID.isEmpty,
              deeplinkWorkspaceNavigationRequest == nil,
              workspaces.contains(where: { !$0.terminals.isEmpty }) else {
            return
        }
        latencyProbeAutoNavigationTask = Task { @MainActor [weak self] in
            defer { self?.latencyProbeAutoNavigationTask = nil }
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self,
                      self.connectionState == .connected,
                      self.terminalOutputStreamTokensBySurfaceID.isEmpty,
                      self.deeplinkWorkspaceNavigationRequest == nil,
                      let workspaceID = self.workspaces.first(where: {
                          !$0.terminals.isEmpty
                      })?.id,
                      MobileLatencyProbe.claimAutoNavigation() else {
                    return
                }
                self.navigateToWorkspaceForDeeplink(workspaceID, origin: .external)
            } catch {
                return
            }
        }
    }

    func startLatencyProbeIfReady() {
        guard connectionState == .connected,
              latencyProbeTask == nil,
              let surfaceID = terminalOutputStreamTokensBySurfaceID.keys.first,
              let configuration = MobileLatencyProbe.claimConfiguration() else {
            return
        }
        latencyProbeTask = Task { @MainActor [weak self] in
            defer { self?.latencyProbeTask = nil }
            do {
                try await Task.sleep(for: .seconds(3))
                for index in 0..<configuration.count {
                    try Task.checkCancellation()
                    guard let self,
                          self.connectionState == .connected,
                          self.hasTerminalOutputSink(surfaceID: surfaceID) else {
                        return
                    }
                    MobileLatencyTrace.stamp("probe.send", "i=\(index)")
                    self.sendTerminalRawInput(
                        MobileLatencyProbe.input(at: index),
                        surfaceID: surfaceID
                    )
                    if index + 1 < configuration.count {
                        try await Task.sleep(
                            for: .milliseconds(configuration.intervalMilliseconds)
                        )
                    }
                }
            } catch {
                return
            }
        }
    }

    func cancelLatencyProbe() {
        latencyProbeAutoNavigationTask?.cancel()
        latencyProbeAutoNavigationTask = nil
        latencyProbeTask?.cancel()
        latencyProbeTask = nil
    }
}
#endif
