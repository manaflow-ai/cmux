import ExtensionFoundation
import ExtensionKit
import Foundation
import AppKit
import SwiftUI

private enum SampleExtensionConstants {
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
        PrimitiveAppExtensionScene(id: SampleExtensionConstants.sceneID) {
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
final class RightSidebarSampleExtension: CmuxRightSidebarExtension {
    required init() {}

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.cmuxterm.app.debug.extkit", name: "right-sidebar-panel")
    }

    var body: some CmuxRightSidebarScene {
        CmuxRightSidebarPanelScene {
            BYOSidebarSampleView()
        }
    }
}

private struct BYOSidebarSampleView: View {
    @State private var selectedTab = SampleTab.actions
    @State private var selectedMode = SampleMode.run
    @State private var selectedModel = SampleModel.fast
    @State private var selectedPriority = SamplePriority.normal
    @State private var selectedScope = SampleScope.session
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
            header

            Picker(
                String(localized: "sampleExtension.tabs", defaultValue: "Tabs"),
                selection: $selectedTab
            ) {
                ForEach(SampleTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch selectedTab {
                    case .actions:
                        actionsTab
                    case .inputs:
                        inputsTab
                    case .settings:
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

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "sampleExtension.title", defaultValue: "BYO controls"))
                    .font(.system(size: 14, weight: .semibold))
                Text(String(localized: "sampleExtension.subtitle", defaultValue: "External ExtensionKit app"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
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
                    ForEach(SampleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
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
                    ForEach(SampleModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }

                Picker(
                    String(localized: "sampleExtension.priority", defaultValue: "Priority"),
                    selection: $selectedPriority
                ) {
                    ForEach(SamplePriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
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
                        Picker(
                            String(localized: "sampleExtension.scope", defaultValue: "Scope"),
                            selection: $selectedScope
                        ) {
                            ForEach(SampleScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
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
            String(localized: "sampleExtension.mode", defaultValue: "Mode") + ": \(selectedMode.title)",
            String(localized: "sampleExtension.model", defaultValue: "Model") + ": \(selectedModel.title)",
            String(localized: "sampleExtension.priority", defaultValue: "Priority") + ": \(selectedPriority.title)",
            String(localized: "sampleExtension.batchSize", defaultValue: "Batch size") + ": \(batchSize)"
        ].joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot, forType: .string)
        lastAction = String(
            localized: "sampleExtension.actionCopied",
            defaultValue: "Snapshot copied"
        )
    }

    private func resetControls() {
        selectedTab = .actions
        selectedMode = .run
        selectedModel = .fast
        selectedPriority = .normal
        selectedScope = .session
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

private enum SampleTab: String, CaseIterable, Identifiable {
    case actions
    case inputs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions:
            String(localized: "sampleExtension.tab.actions", defaultValue: "Actions")
        case .inputs:
            String(localized: "sampleExtension.tab.inputs", defaultValue: "Inputs")
        case .settings:
            String(localized: "sampleExtension.tab.settings", defaultValue: "Settings")
        }
    }
}

private enum SampleMode: String, CaseIterable, Identifiable {
    case run
    case review
    case watch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .run:
            String(localized: "sampleExtension.mode.run", defaultValue: "Run")
        case .review:
            String(localized: "sampleExtension.mode.review", defaultValue: "Review")
        case .watch:
            String(localized: "sampleExtension.mode.watch", defaultValue: "Watch")
        }
    }
}

private enum SampleModel: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            String(localized: "sampleExtension.model.fast", defaultValue: "Fast")
        case .balanced:
            String(localized: "sampleExtension.model.balanced", defaultValue: "Balanced")
        case .deep:
            String(localized: "sampleExtension.model.deep", defaultValue: "Deep")
        }
    }
}

private enum SamplePriority: String, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            String(localized: "sampleExtension.priority.low", defaultValue: "Low")
        case .normal:
            String(localized: "sampleExtension.priority.normal", defaultValue: "Normal")
        case .high:
            String(localized: "sampleExtension.priority.high", defaultValue: "High")
        }
    }
}

private enum SampleScope: String, CaseIterable, Identifiable {
    case session
    case project
    case workspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session:
            String(localized: "sampleExtension.scope.session", defaultValue: "Session")
        case .project:
            String(localized: "sampleExtension.scope.project", defaultValue: "Project")
        case .workspace:
            String(localized: "sampleExtension.scope.workspace", defaultValue: "Workspace")
        }
    }
}
