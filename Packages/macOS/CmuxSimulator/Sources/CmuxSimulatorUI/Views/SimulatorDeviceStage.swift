import AppKit
import CmuxSimulator
import SwiftUI

let simulatorDeviceStagePadding: CGFloat = 22

struct SimulatorDeviceStage: View {
    let coordinator: SimulatorPaneCoordinator
    let backgroundColor: Color
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let onRequestPanelFocus: @MainActor () -> Void

    var body: some View {
        ZStack {
            backgroundColor
            if coordinator.devices.isEmpty, coordinator.failure == nil {
                ContentUnavailableView {
                    Label(simulatorStrings.noDevices, systemImage: "iphone.slash")
                } description: {
                    Text(simulatorStrings.noDevicesHelp)
                } actions: {
                    Button(simulatorStrings.refresh) {
                        coordinator.scheduleControlAction("reload-devices") { _ = await $0.reloadDevices() }
                    }
                }
            } else if let failure = coordinator.failure,
                coordinator.frameTransport == nil
            {
                failureView(failure)
            } else if let display = coordinator.display,
                let frameTransport = coordinator.frameTransport
            {
                device(display: display, frameTransport: frameTransport)
            } else {
                waitingView
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard coordinator.canImportDroppedFiles(urls) else { return false }
            coordinator.scheduleControlAction("import-dropped-files") {
                await $0.importDroppedFiles(urls)
            }
            return true
        }
    }

    private func device(
        display: SimulatorDisplayMetadata,
        frameTransport: SimulatorFrameTransportDescriptor
    ) -> some View {
        ZStack {
            SimulatorRemoteSurface(
                coordinator: coordinator,
                frameTransport: frameTransport,
                display: display,
                chrome: coordinator.chromeProfile,
                allowsPointerInput: allowsPointerInput,
                pointerEntryEventFilter: pointerEntryEventFilter,
                onRequestPanelFocus: onRequestPanelFocus
            )
            if coordinator.accessibilityOverlayEnabled
                || coordinator.highlightedAccessibilityNodeID != nil,
                let snapshot = coordinator.accessibilitySnapshot
            {
                SimulatorAccessibilityOverlay(
                    snapshot: snapshot,
                    rows: coordinator.accessibilityRows,
                    selectedNodeID: coordinator.accessibilityOverlaySelectedNodeID,
                    highlightedNodeID: coordinator.highlightedAccessibilityNodeID,
                    chrome: coordinator.chromeProfile,
                    onSelect: { coordinator.selectAccessibilityOverlayNode($0) }
                )
            }
        }
        .aspectRatio(
            coordinator.chromeProfile?.outerAspect(orientation: display.orientation)
                ?? SimulatorOrientationGeometry(display: display).displayAspectRatio,
            contentMode: .fit
        )
        .clipShape(.rect(cornerRadius: coordinator.chromeProfile == nil ? deviceCornerRadius : 0))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(simulatorDeviceStagePadding)
        .accessibilityLabel(simulatorStrings.simulator)
    }

    @ViewBuilder
    private func failureView(_ failure: SimulatorFailure) -> some View {
        ContentUnavailableView {
            Label(simulatorStrings.failed, systemImage: "exclamationmark.triangle")
        } description: {
            Text(simulatorStrings.failure(failure.code))
        } actions: {
            if failure.isRecoverable {
                Button(simulatorStrings.reconnect) { coordinator.recover() }
            }
        }
    }

    @ViewBuilder
    private var waitingView: some View {
        switch coordinator.status {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView()
                Text(simulatorStrings.connecting).foregroundStyle(.secondary)
            }
        case .workerCrashed:
            ContentUnavailableView {
                Label(simulatorStrings.workerStopped, systemImage: "bolt.slash")
            } actions: {
                Button(simulatorStrings.reconnect) { coordinator.recover() }
            }
        default:
            ContentUnavailableView(
                simulatorStrings.selectToStart,
                systemImage: "iphone",
                description: nil
            )
        }
    }

    private var deviceCornerRadius: CGFloat {
        selectedFamily == .iPad ? 22 : 34
    }

    private var selectedFamily: SimulatorDeviceFamily? {
        coordinator.devices.first(where: { $0.id == coordinator.selectedDeviceID })?.family
    }
}
