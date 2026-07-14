import AppKit
import CmuxFoundation
import CmuxSimulator
import SwiftUI

/// Renders a ``SimulatorPanel``: the latest display frame fitted into the
/// pane, with a status footer while the session is not streaming yet and a
/// readable failure state.
struct SimulatorPanelView: View {
    @ObservedObject var panel: SimulatorPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        SimulatorPaneContent(model: panel.model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                onRequestPanelFocus()
            }
    }
}

/// The model-driven content; separated so Observation tracking re-evaluates
/// only this subtree as frames arrive.
private struct SimulatorPaneContent: View {
    let model: SimulatorPaneModel
    /// The last decoded frame, cached by sequence so a body re-evaluation
    /// never re-decodes unchanged image data.
    @State private var decodedFrame: (sequence: Int, image: NSImage)?

    var body: some View {
        ZStack {
            if let decodedFrame {
                Image(nsImage: decodedFrame.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .accessibilityLabel(deviceLabel)
            }
            if decodedFrame == nil || !isStreaming {
                statusOverlay
            }
        }
        .onChange(of: model.latestFrame) { _, frame in
            decode(frame)
        }
        .onAppear {
            decode(model.latestFrame)
        }
    }

    private var isStreaming: Bool {
        model.phase == .streaming
    }

    private var deviceLabel: String {
        model.device?.name ?? model.deviceQuery
    }

    private func decode(_ frame: SimulatorDisplayFrame?) {
        guard let frame, frame.sequence != decodedFrame?.sequence else { return }
        guard let image = NSImage(data: frame.imageData) else { return }
        decodedFrame = (frame.sequence, image)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle, .resolvingDevice:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "simulatorPane.phase.resolving", defaultValue: "Finding simulator device…"))
                    .cmuxFont(size: 13, weight: .semibold)
            case .booting:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "simulatorPane.phase.booting", defaultValue: "Booting simulator…"))
                    .cmuxFont(size: 13, weight: .semibold)
                Text(deviceLabel)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            case .attaching:
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "simulatorPane.phase.attaching", defaultValue: "Attaching to running simulator…"))
                    .cmuxFont(size: 13, weight: .semibold)
                Text(deviceLabel)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            case .streaming:
                // First frame not decoded yet.
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "simulatorPane.phase.waitingForFrames", defaultValue: "Waiting for the first frame…"))
                    .cmuxFont(size: 13, weight: .semibold)
            case .stopped:
                CmuxSystemSymbolImage(systemName: "iphone.slash", pointSize: 18)
                    .foregroundStyle(.secondary)
                Text(String(localized: "simulatorPane.phase.stopped", defaultValue: "Simulator session ended"))
                    .cmuxFont(size: 13, weight: .semibold)
            case .failed(let failure):
                CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18)
                    .foregroundStyle(.orange)
                Text(failureHeadline(failure))
                    .cmuxFont(size: 13, weight: .semibold)
                if case .sessionFailed(let detail) = failure {
                    Text(detail)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
        }
        .padding(24)
    }

    private func failureHeadline(_ failure: SimulatorPaneFailure) -> String {
        switch failure {
        case .deviceNotFound(let query):
            return String(
                format: String(
                    localized: "simulatorPane.failed.deviceNotFound",
                    defaultValue: "No simulator device matched “%@”."
                ),
                query
            )
        case .sessionFailed:
            return String(localized: "simulatorPane.failed.headline", defaultValue: "The simulator session failed.")
        }
    }
}
