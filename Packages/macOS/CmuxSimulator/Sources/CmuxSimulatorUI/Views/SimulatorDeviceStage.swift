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
    var phoneControlTeaser: SimulatorPhoneControlTeaser? = nil

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
        let family = selectedFamily
        let maximumSize = maximumDeviceSize(for: display, family: family)
        return ZStack {
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
        .frame(maxWidth: maximumSize?.width, maxHeight: maximumSize?.height)
        .clipShape(.rect(
            cornerRadius: coordinator.chromeProfile == nil
                ? deviceCornerRadius(for: family)
                : 0
        ))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(simulatorDeviceStagePadding)
        .accessibilityLabel(simulatorStrings.simulator)
        .overlay(alignment: .bottom) {
            if let phoneControlTeaser {
                phoneControlTeaserChip(phoneControlTeaser)
            }
        }
    }

    /// One-time cross-device teaser shown only over a LIVE stage: the moment
    /// a user first sees their Simulator streaming in a pane is the moment
    /// the phone-control payoff is most believable.
    private func phoneControlTeaserChip(
        _ teaser: SimulatorPhoneControlTeaser
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(simulatorStrings.phoneControlTeaser)
                .font(.callout)
            Button(simulatorStrings.phoneControlTeaserAction) {
                teaser.openPairing()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                teaser.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(simulatorStrings.phoneControlTeaserDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 6)
        .accessibilityIdentifier("SimulatorPhoneControlTeaser")
    }

    private func maximumDeviceSize(
        for display: SimulatorDisplayMetadata,
        family: SimulatorDeviceFamily?
    ) -> CGSize? {
        guard family == .iPhone else { return nil }
        if let chrome = coordinator.chromeProfile {
            return switch display.orientation {
            case .portrait, .portraitUpsideDown:
                CGSize(width: chrome.portraitWidth, height: chrome.portraitHeight)
            case .landscapeLeft, .landscapeRight:
                CGSize(width: chrome.portraitHeight, height: chrome.portraitWidth)
            }
        }
        // The fallback caps the framebuffer itself. A later chrome profile adds
        // only its measured insets around that same 1:1 framebuffer.
        guard display.scale.isFinite, display.scale > 0 else { return nil }
        let geometry = SimulatorOrientationGeometry(display: display)
        return CGSize(
            width: Double(geometry.displayWidth) / display.scale,
            height: Double(geometry.displayHeight) / display.scale
        )
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
            // Teaching empty state: name the next step and the payoff, and
            // offer the fastest path — one click boots the most recently used
            // device; the embedded picker is the same menu as the toolbar's.
            ContentUnavailableView {
                Label(simulatorStrings.selectToStart, systemImage: "iphone")
            } description: {
                Text(simulatorStrings.selectToStartHelp)
            } actions: {
                if let suggestion = quickStartDevice {
                    Button(simulatorStrings.quickStart(suggestion.name)) {
                        coordinator.selectDevice(id: suggestion.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
                SimulatorDevicePicker(coordinator: coordinator)
            }
        }
    }

    /// The one-click boot suggestion: the most recently booted available
    /// device, falling back to the first available one.
    private var quickStartDevice: SimulatorDevice? {
        coordinator.devices
            .filter(\.isAvailable)
            .max(by: { ($0.lastBootedAt ?? .distantPast) < ($1.lastBootedAt ?? .distantPast) })
    }

    private func deviceCornerRadius(
        for family: SimulatorDeviceFamily?
    ) -> CGFloat {
        family == .iPad ? 22 : 34
    }

    private var selectedFamily: SimulatorDeviceFamily? {
        coordinator.devices.first(where: { $0.id == coordinator.selectedDeviceID })?.family
    }
}
