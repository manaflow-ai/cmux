#if DEBUG
import CmuxMobileDiagnostics
import Foundation

extension MobileShellComposite {
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
        latencyProbeTask?.cancel()
        latencyProbeTask = nil
    }
}
#endif
