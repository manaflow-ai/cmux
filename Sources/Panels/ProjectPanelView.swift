import AppKit
import CMUXProjectModel
import SwiftUI

/// Top-level SwiftUI view for a ``ProjectPanel``.
///
/// Renders the project chrome (project name, scheme/configuration pickers,
/// tab strip) and dispatches into the per-tab subviews.
struct ProjectPanelView: View {
    @ObservedObject var panel: ProjectPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if case .idle = panel.loadState {
                panel.reload()
            }
        }
    }

    @ViewBuilder
    private var chrome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(panel.displayTitle, systemImage: "hammer.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .help(panel.projectURL.path)
                schemePicker
                configurationPicker
                Spacer(minLength: 0)
                Button {
                    panel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Reload project")
            }
            if let error = panel.lastLoadError, case .loaded = panel.loadState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Reload returned errors: \(error)")
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        panel.lastLoadError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            tabStrip
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var allSchemes: [SchemeSummary] {
        guard let model = panel.loadState.model else { return [] }
        var seen: Set<String> = []
        var out: [SchemeSummary] = []
        for module in model.modules {
            for scheme in module.schemes where seen.insert(scheme.name).inserted {
                out.append(scheme)
            }
        }
        return out
    }

    private var allConfigurationNames: [String] {
        guard let model = panel.loadState.model else { return [] }
        var seen: Set<String> = []
        var out: [String] = []
        for module in model.modules {
            for name in module.configurationNames where seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    @ViewBuilder
    private var schemePicker: some View {
        let schemes = allSchemes
        if !schemes.isEmpty {
            Picker(
                "Scheme",
                selection: Binding(
                    get: { panel.selectedSchemeName ?? schemes.first?.name ?? "" },
                    set: { panel.selectedSchemeName = $0 }
                )
            ) {
                ForEach(schemes) { scheme in
                    Text(scheme.name).tag(scheme.name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private var configurationPicker: some View {
        let names = allConfigurationNames
        if !names.isEmpty {
            Picker(
                "Configuration",
                selection: Binding(
                    get: { panel.selectedConfigurationName ?? names.first ?? "" },
                    set: { panel.selectedConfigurationName = $0 }
                )
            ) {
                ForEach(names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 180, maxWidth: 240)
        }
    }

    @ViewBuilder
    private var pathHint: some View {
        EmptyView()
    }

    @ViewBuilder
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(ProjectPanelTab.allCases, id: \.self) { tab in
                Button(action: { panel.activeTab = tab }) {
                    Text(tab.displayLabel)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(panel.activeTab == tab
                                      ? Color.accentColor
                                      : Color.secondary.opacity(0.10))
                        )
                        .foregroundStyle(panel.activeTab == tab ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.loadState {
        case .idle, .loading:
            ProjectPanelStatusView(message: "Loading \(panel.displayTitle)")
        case let .failed(reason):
            ProjectPanelStatusView(message: "Failed: \(reason)")
        case let .loaded(model):
            tabContent(for: model)
        }
    }

    @ViewBuilder
    private func tabContent(for model: ProjectModel) -> some View {
        switch panel.activeTab {
        case .files:
            ProjectFilesTabView(panel: panel, model: model)
        case .targets:
            ProjectTargetsTabView(panel: panel, model: model)
        case .buildSettings:
            ProjectBuildSettingsTabView(panel: panel, model: model)
        case .schemes:
            ProjectSchemesTabView(panel: panel, model: model)
        }
    }
}

struct ProjectPanelStatusView: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reusable empty-state placeholder for the detail panes of each tab.
///
/// Replaces the floating 12 pt secondary text that read as a loading bug.
/// Centered icon (tertiary), 13 pt semibold title, 11 pt secondary hint.
struct ProjectEmptyDetailView: View {
    let systemImage: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .multilineTextAlignment(.center)
    }
}
