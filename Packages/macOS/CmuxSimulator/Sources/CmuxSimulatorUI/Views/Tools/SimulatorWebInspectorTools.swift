import CmuxSimulator
import SwiftUI

struct SimulatorWebInspectorTools: View {
    let coordinator: SimulatorPaneCoordinator

    var body: some View {
        SimulatorWebInspectorToolsContent(
            isAvailable: coordinator.supports(.webInspector),
            targets: coordinator.webInspectorTargets,
            session: coordinator.webInspectorSession,
            isHighlighted: coordinator.webInspectorIsHighlighted,
            responses: coordinator.webInspectorResponses,
            refresh: { Task { await coordinator.refreshWebInspectorTargets() } },
            attach: { targetID in Task { await coordinator.attachWebInspector(targetID: targetID) } },
            release: { Task { await coordinator.releaseWebInspector() } },
            setHighlight: { enabled in
                Task { await coordinator.setWebInspectorHighlight(enabled: enabled) }
            },
            send: { json in Task { await coordinator.sendWebInspectorMessage(json) } },
            clearResponses: coordinator.clearWebInspectorResponses
        )
        .task(id: coordinator.contextID) {
            guard coordinator.contextID != nil, coordinator.supports(.webInspector) else { return }
            await coordinator.refreshWebInspectorTargets()
        }
    }
}

private struct SimulatorWebInspectorToolsContent: View {
    let isAvailable: Bool
    let targets: [SimulatorWebInspectorTarget]
    let session: SimulatorWebInspectorSessionStatus
    let isHighlighted: Bool
    let responses: [SimulatorWebInspectorResponse]
    let refresh: () -> Void
    let attach: (String) -> Void
    let release: () -> Void
    let setHighlight: (Bool) -> Void
    let send: (String) -> Void
    let clearResponses: () -> Void

    var body: some View {
        SimulatorToolSection(simulatorStrings.webInspector) {
            SimulatorWebInspectorTargetPicker(
                isAvailable: isAvailable,
                targets: targets,
                session: session,
                refresh: refresh,
                attach: attach,
                release: release
            )
            SimulatorWebInspectorCommandEditor(
                isAttached: attachedTargetID != nil,
                isHighlighted: isHighlighted,
                setHighlight: setHighlight,
                send: send
            )
            SimulatorWebInspectorResponses(
                responses: responses,
                clear: clearResponses
            )
        }
    }

    private var attachedTargetID: String? {
        guard case let .attached(_, targetID) = session else { return nil }
        return targetID
    }
}

private struct SimulatorWebInspectorTargetPicker: View {
    let isAvailable: Bool
    let targets: [SimulatorWebInspectorTarget]
    let session: SimulatorWebInspectorSessionStatus
    let refresh: () -> Void
    let attach: (String) -> Void
    let release: () -> Void

    var body: some View {
        HStack {
            Button(simulatorStrings.refreshTargets, action: refresh)
                .disabled(!isAvailable)
            Menu {
                ForEach(targets) { target in
                    Button {
                        attach(target.id)
                    } label: {
                        Text(verbatim: targetLabel(target))
                    }
                    .disabled(target.isInUse)
                }
            } label: {
                Label(simulatorStrings.chooseTarget, systemImage: "scope")
            }
            .disabled(!isAvailable || targets.isEmpty)
            if case .attached = session {
                Button(simulatorStrings.releaseInspector, action: release)
            }
        }

        if targets.isEmpty {
            Text(isAvailable ? simulatorStrings.noInspectorTargets : simulatorStrings.webInspectorUnavailable)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let target = attachedTarget {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: target.title.isEmpty ? target.url : target.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: target.url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(verbatim: target.bundleIdentifier ?? target.applicationName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachedTarget: SimulatorWebInspectorTarget? {
        guard case let .attached(_, targetID) = session else { return nil }
        return targets.first(where: { $0.id == targetID })
    }

    private func targetLabel(_ target: SimulatorWebInspectorTarget) -> String {
        let page = target.title.isEmpty ? target.url : target.title
        let suffix = target.isInUse ? " · \(String(localized: simulatorStrings.inUse))" : ""
        return "\(target.applicationName) · \(page)\(suffix)"
    }
}

private struct SimulatorWebInspectorCommandEditor: View {
    let isAttached: Bool
    let isHighlighted: Bool
    let setHighlight: (Bool) -> Void
    let send: (String) -> Void

    @State private var rawJSON =
        #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.title"}}"#

    var body: some View {
        HStack {
            Button(
                isHighlighted ? simulatorStrings.unhighlightPage : simulatorStrings.highlightPage
            ) {
                setHighlight(!isHighlighted)
            }
            .disabled(!isAttached)
            Spacer()
            Button(simulatorStrings.sendInspectorCommand) { send(rawJSON) }
                .disabled(!isAttached || rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        TextEditor(text: $rawJSON)
            .font(.caption.monospaced())
            .frame(minHeight: 88)
            .accessibilityLabel(simulatorStrings.rawInspectorRequest)
    }
}

private struct SimulatorWebInspectorResponses: View {
    let responses: [SimulatorWebInspectorResponse]
    let clear: () -> Void

    var body: some View {
        HStack {
            Text(simulatorStrings.inspectorResponses)
                .font(.caption.weight(.medium))
            Spacer()
            Button(simulatorStrings.clearInspectorResponses, action: clear)
                .disabled(responses.isEmpty)
        }
        if responses.isEmpty {
            Text(simulatorStrings.noInspectorResponses)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(responses) { response in
                VStack(alignment: .leading, spacing: 2) {
                    if response.isTruncated {
                        Text(simulatorStrings.truncatedInspectorResponse)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(verbatim: response.text)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
