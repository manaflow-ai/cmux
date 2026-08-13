import AppKit
import CmuxSimulator
import SwiftUI

struct SimulatorInspectionTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorToolSection(simulatorStrings.inspect) {
            Button(simulatorStrings.foregroundApp) {
                coordinator.scheduleControlAction("refresh-foreground") {
                    await $0.refreshForegroundApplication()
                }
            }
                .disabled(!coordinator.supports(.foregroundApplication))
            if let application = coordinator.foregroundApplication {
                applicationHeader(application)
                if let processIdentifier = application.processIdentifier {
                    LabeledContent(
                        String(localized: simulatorStrings.processIdentifier),
                        value: String(processIdentifier)
                    )
                }
                if let version = application.version {
                    LabeledContent(String(localized: simulatorStrings.version), value: version)
                }
                if let build = application.build {
                    LabeledContent(String(localized: simulatorStrings.build), value: build)
                }
                if let minimumOSVersion = application.minimumOSVersion {
                    LabeledContent(
                        String(localized: simulatorStrings.minimumOSVersion),
                        value: minimumOSVersion
                    )
                }
                if let executable = application.executable {
                    LabeledContent(String(localized: simulatorStrings.executable), value: executable)
                }
                if let bundlePath = application.bundlePath {
                    LabeledContent(String(localized: simulatorStrings.applicationPath)) {
                        Text(verbatim: bundlePath)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(simulatorStrings.revealInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: bundlePath, isDirectory: true),
                        ])
                    }
                }
                LabeledContent(
                    String(localized: simulatorStrings.reactNative),
                    value: String(localized: application.isReactNative ? simulatorStrings.yes : simulatorStrings.no)
                )
                if application.isReactNative {
                    Button(simulatorStrings.reloadReactNative) {
                        coordinator.scheduleControlAction("reload-react-native") {
                            await $0.reloadReactNative()
                        }
                    }
                }
            }
            Button(simulatorStrings.accessibility) {
                coordinator.scheduleControlAction("refresh-accessibility") {
                    await $0.refreshAccessibility()
                }
            }
                .disabled(!coordinator.supports(.accessibility))
            Toggle(
                simulatorStrings.accessibilityOverlay,
                isOn: Binding(
                    get: { coordinator.accessibilityOverlayEnabled },
                    set: { coordinator.setAccessibilityOverlayEnabled($0) }
                )
            )
                .disabled(!coordinator.supports(.accessibility))
            if let snapshot = coordinator.accessibilitySnapshot {
                Text(simulatorStrings.accessibilityNodeCount(snapshot.nodeCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.isTruncated {
                    Text(simulatorStrings.accessibilityTruncated)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                SimulatorAccessibilityPagedTree(
                    rows: coordinator.accessibilityRows,
                    highlightedNodeID: coordinator.highlightedAccessibilityNodeID
                ) { node in
                    coordinator.scheduleControlAction("accessibility-highlight") {
                        await $0.highlightAccessibilityNode(node)
                    }
                }
                if coordinator.highlightedAccessibilityNodeID != nil {
                    Button(simulatorStrings.clearHighlight) {
                        coordinator.scheduleControlAction("accessibility-highlight") {
                            await $0.clearAccessibilityHighlight()
                        }
                    }
                }
            }
        }
        .task(id: coordinator.frameTransport) {
            guard coordinator.frameTransport != nil else { return }
            await coordinator.refreshForegroundApplication()
            await coordinator.refreshAccessibility()
        }
    }

    private func applicationHeader(_ application: SimulatorApplicationInfo) -> some View {
        HStack(spacing: 8) {
            if let bundlePath = application.bundlePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(.rect(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: application.name ?? application.bundleIdentifier).font(.caption)
                Text(verbatim: application.bundleIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
