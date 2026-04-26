#if compiler(>=6.3) && canImport(ExtensionFoundation) && canImport(ExtensionKit)
import ExtensionFoundation
import ExtensionKit
import Foundation
import AppKit
import SwiftUI

private enum DemoExtensionConstants {
    static let sceneID = "cmux-right-sidebar-demo"
}

protocol CmuxRightSidebarExtension: AppExtension {
    associatedtype Body: CmuxRightSidebarScene
    var body: Body { get }
}

protocol CmuxRightSidebarScene: AppExtensionScene {}

struct CmuxRightSidebarPanelScene<Content: View>: CmuxRightSidebarScene {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some AppExtensionScene {
        PrimitiveAppExtensionScene(id: DemoExtensionConstants.sceneID) {
            content()
        } onConnection: { connection in
            connection.resume()
            return true
        }
    }
}

extension CmuxRightSidebarExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(self.body)
    }
}

@main
final class RightSidebarDemoExtension: CmuxRightSidebarExtension {
    required init() {}

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        #if CMUX_RELEASE_EXTENSION_POINT
        AppExtensionPoint.Identifier(host: "com.cmuxterm.app", name: "right-sidebar-panel")
        #else
        AppExtensionPoint.Identifier(host: "com.cmuxterm.app.debug.extkit", name: "right-sidebar-panel")
        #endif
    }

    var body: some CmuxRightSidebarScene {
        CmuxRightSidebarPanelScene {
            RightSidebarDemoExtensionView()
        }
    }
}

private struct RightSidebarDemoExtensionView: View {
    @State private var selectedTab = 0
    @State private var selectedMode = 0
    @State private var selectedModel = 0
    @State private var selectedPriority = 1
    @State private var selectedScope = 0
    @State private var title: String
    @State private var secret = ""
    @State private var notes = ""
    @State private var isPinned = true
    @State private var notificationsEnabled = true
    @State private var compactLayout = false
    @State private var livePreview = true
    @State private var confidence = 0.62
    @State private var batchSize = 4
    @State private var dueDate = Date()
    @State private var accentColor = Color.green
    @State private var actionCount = 0
    @State private var lastAction: String

    init() {
        _title = State(initialValue: String(
            localized: "sampleExtension.defaultTitle",
            defaultValue: "Draft launch plan"
        ))
        _lastAction = State(initialValue: String(
            localized: "sampleExtension.actionReady",
            defaultValue: "Ready"
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "sampleExtension.title", defaultValue: "BYO controls"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "rightSidebar.demoExtension.subtitle", defaultValue: "Rendered by ExtensionKit"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Picker(
                String(localized: "sampleExtension.tabs", defaultValue: "Tabs"),
                selection: $selectedTab
            ) {
                Text(String(localized: "sampleExtension.tab.actions", defaultValue: "Actions")).tag(0)
                Text(String(localized: "sampleExtension.tab.inputs", defaultValue: "Inputs")).tag(1)
                Text(String(localized: "sampleExtension.tab.settings", defaultValue: "Settings")).tag(2)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch selectedTab {
                    case 0:
                        actionsTab
                    case 1:
                        inputsTab
                    default:
                        settingsTab
                    }
                }
                .padding(.bottom, 4)
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var actionsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(
                title: String(localized: "sampleExtension.quickActions", defaultValue: "Quick actions"),
                systemImage: "bolt"
            ) {
                Picker(
                    String(localized: "sampleExtension.mode", defaultValue: "Mode"),
                    selection: $selectedMode
                ) {
                    Text(String(localized: "sampleExtension.mode.run", defaultValue: "Run")).tag(0)
                    Text(String(localized: "sampleExtension.mode.review", defaultValue: "Review")).tag(1)
                    Text(String(localized: "sampleExtension.mode.watch", defaultValue: "Watch")).tag(2)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Button {
                        actionCount += 1
                        lastAction = String(
                            localized: "sampleExtension.actionRan",
                            defaultValue: "Run button clicked"
                        )
                    } label: {
                        Label(
                            String(localized: "sampleExtension.run", defaultValue: "Run"),
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        copySnapshot()
                    } label: {
                        Label(
                            String(localized: "sampleExtension.copy", defaultValue: "Copy"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .controlSize(.small)

                    Button {
                        resetControls()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(String(localized: "sampleExtension.reset", defaultValue: "Reset"))
                    .accessibilityLabel(String(localized: "sampleExtension.reset", defaultValue: "Reset"))
                }

                Toggle(isOn: $isPinned) {
                    Label(
                        String(localized: "sampleExtension.pinned", defaultValue: "Pinned"),
                        systemImage: "pin"
                    )
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 8) {
                    Text(String(localized: "sampleExtension.count", defaultValue: "Count"))
                    Spacer(minLength: 0)
                    Text("\(actionCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            section(
                title: String(localized: "sampleExtension.liveStatus", defaultValue: "Live status"),
                systemImage: "waveform.path.ecg"
            ) {
                ProgressView(value: confidence)
                    .accessibilityLabel(String(localized: "sampleExtension.confidence", defaultValue: "Confidence"))
                    .accessibilityValue(confidence.formatted(.percent.precision(.fractionLength(0))))
                Text(lastAction)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var inputsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(
                title: String(localized: "sampleExtension.textInputs", defaultValue: "Text inputs"),
                systemImage: "text.cursor"
            ) {
                TextField(
                    String(localized: "sampleExtension.titleField", defaultValue: "Title"),
                    text: $title
                )
                SecureField(
                    String(localized: "sampleExtension.secretField", defaultValue: "Secret"),
                    text: $secret
                )

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $notes)
                        .font(.system(size: 11))
                        .frame(minHeight: 76)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(String(
                            localized: "sampleExtension.notesPlaceholder",
                            defaultValue: "Write sidebar notes..."
                        ))

                    if notes.isEmpty {
                        Text(String(localized: "sampleExtension.notesPlaceholder", defaultValue: "Write sidebar notes..."))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            section(
                title: String(localized: "sampleExtension.formControls", defaultValue: "Form controls"),
                systemImage: "list.bullet.rectangle"
            ) {
                Picker(
                    String(localized: "sampleExtension.model", defaultValue: "Model"),
                    selection: $selectedModel
                ) {
                    Text(String(localized: "sampleExtension.model.fast", defaultValue: "Fast")).tag(0)
                    Text(String(localized: "sampleExtension.model.balanced", defaultValue: "Balanced")).tag(1)
                    Text(String(localized: "sampleExtension.model.deep", defaultValue: "Deep")).tag(2)
                }

                Picker(
                    String(localized: "sampleExtension.priority", defaultValue: "Priority"),
                    selection: $selectedPriority
                ) {
                    Text(String(localized: "sampleExtension.priority.low", defaultValue: "Low")).tag(0)
                    Text(String(localized: "sampleExtension.priority.normal", defaultValue: "Normal")).tag(1)
                    Text(String(localized: "sampleExtension.priority.high", defaultValue: "High")).tag(2)
                }

                Stepper(value: $batchSize, in: 1...12) {
                    Text(String(
                        localized: "sampleExtension.batchSize",
                        defaultValue: "Batch size"
                    ) + ": \(batchSize)")
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "sampleExtension.confidence", defaultValue: "Confidence"))
                        Spacer(minLength: 0)
                        Text(confidence.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))

                    Slider(value: $confidence, in: 0...1)
                        .accessibilityLabel(String(localized: "sampleExtension.confidence", defaultValue: "Confidence"))
                        .accessibilityValue(confidence.formatted(.percent.precision(.fractionLength(0))))
                }

                DatePicker(
                    String(localized: "sampleExtension.dueDate", defaultValue: "Due date"),
                    selection: $dueDate,
                    displayedComponents: [.date]
                )

                ColorPicker(
                    String(localized: "sampleExtension.accent", defaultValue: "Accent"),
                    selection: $accentColor
                )
            }
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(
                title: String(localized: "sampleExtension.toggles", defaultValue: "Toggles"),
                systemImage: "switch.2"
            ) {
                Toggle(
                    String(localized: "sampleExtension.notifications", defaultValue: "Notifications"),
                    isOn: $notificationsEnabled
                )
                Toggle(
                    String(localized: "sampleExtension.compactLayout", defaultValue: "Compact layout"),
                    isOn: $compactLayout
                )
                Toggle(
                    String(localized: "sampleExtension.livePreview", defaultValue: "Live preview"),
                    isOn: $livePreview
                )
            }

            section(
                title: String(localized: "sampleExtension.advanced", defaultValue: "Advanced"),
                systemImage: "gearshape.2"
            ) {
                DisclosureGroup(String(localized: "sampleExtension.advancedOptions", defaultValue: "Advanced options")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(String(localized: "sampleExtension.scope", defaultValue: "Scope"), selection: $selectedScope) {
                            Text(String(localized: "sampleExtension.scope.session", defaultValue: "Session")).tag(0)
                            Text(String(localized: "sampleExtension.scope.project", defaultValue: "Project")).tag(1)
                            Text(String(localized: "sampleExtension.scope.workspace", defaultValue: "Workspace")).tag(2)
                        }

                        Gauge(value: confidence) {
                            Text(String(localized: "sampleExtension.readiness", defaultValue: "Readiness"))
                        }
                        .gaugeStyle(.accessoryLinear)

                        Text(ProcessInfo.processInfo.processName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 6) {
                Circle()
                    .fill(livePreview ? accentColor : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(String(localized: "sampleExtension.live", defaultValue: "Live"))
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
                Text(timeline.date, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
                .font(.system(size: 11))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copySnapshot() {
        let snapshot = [
            String(localized: "sampleExtension.titleField", defaultValue: "Title") + ": \(title)",
            String(localized: "sampleExtension.mode", defaultValue: "Mode") + ": \(modeTitle)",
            String(localized: "sampleExtension.model", defaultValue: "Model") + ": \(modelTitle)",
            String(localized: "sampleExtension.priority", defaultValue: "Priority") + ": \(priorityTitle)",
            String(localized: "sampleExtension.batchSize", defaultValue: "Batch size") + ": \(batchSize)"
        ].joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot, forType: .string)
        lastAction = String(
            localized: "sampleExtension.actionCopied",
            defaultValue: "Snapshot copied"
        )
    }

    private var modeTitle: String {
        switch selectedMode {
        case 0:
            String(localized: "sampleExtension.mode.run", defaultValue: "Run")
        case 1:
            String(localized: "sampleExtension.mode.review", defaultValue: "Review")
        case 2:
            String(localized: "sampleExtension.mode.watch", defaultValue: "Watch")
        default:
            "\(selectedMode)"
        }
    }

    private var modelTitle: String {
        switch selectedModel {
        case 0:
            String(localized: "sampleExtension.model.fast", defaultValue: "Fast")
        case 1:
            String(localized: "sampleExtension.model.balanced", defaultValue: "Balanced")
        case 2:
            String(localized: "sampleExtension.model.deep", defaultValue: "Deep")
        default:
            "\(selectedModel)"
        }
    }

    private var priorityTitle: String {
        switch selectedPriority {
        case 0:
            String(localized: "sampleExtension.priority.low", defaultValue: "Low")
        case 1:
            String(localized: "sampleExtension.priority.normal", defaultValue: "Normal")
        case 2:
            String(localized: "sampleExtension.priority.high", defaultValue: "High")
        default:
            "\(selectedPriority)"
        }
    }

    private func resetControls() {
        selectedTab = 0
        selectedMode = 0
        selectedModel = 0
        selectedPriority = 1
        selectedScope = 0
        title = String(localized: "sampleExtension.defaultTitle", defaultValue: "Draft launch plan")
        secret = ""
        notes = ""
        isPinned = true
        notificationsEnabled = true
        compactLayout = false
        livePreview = true
        confidence = 0.62
        batchSize = 4
        dueDate = Date()
        accentColor = .green
        actionCount = 0
        lastAction = String(localized: "sampleExtension.actionReset", defaultValue: "Controls reset")
    }
}
#else
import Foundation

@main
enum RightSidebarDemoExtensionFallback {
    static func main() {}
}
#endif
