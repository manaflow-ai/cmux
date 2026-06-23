import CMUXProjectModel
import CmuxPanes
import SwiftUI

/// Targets tab inside ``ProjectPanelView``.
///
/// Renders a table of targets with their product type, deployment target,
/// bundle id, and dependency count. Selecting a target shows a detail panel
/// listing per-config build settings the target overrides at its scope.
struct ProjectTargetsTabView: View {
    @ObservedObject var panel: ProjectPanel
    let model: ProjectModel

    var body: some View {
        HSplitView {
            targetList
                .frame(minWidth: 320, idealWidth: 420, maxHeight: .infinity)
            targetDetail
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var targetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.modules) { module in
                    if model.modules.count > 1 {
                        Text(module.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                    ForEach(module.targets) { target in
                        targetRow(target, in: module)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func targetRow(_ target: TargetSummary, in module: ProjectModule) -> some View {
        let isSelected = panel.selectedTargetID == target.id
        Button(action: { panel.selectedTargetID = target.id }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: glyph(for: target.productType))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(target.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(target.productType.rawValue)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.18))
                            )
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if let deploy = target.deploymentTarget {
                            metadata("min", deploy)
                        }
                        if !target.platforms.isEmpty {
                            metadata("platforms", target.platforms.joined(separator: ","))
                        }
                        if let bundle = target.bundleIdentifier {
                            metadata("bundle", bundle)
                        }
                        Text("deps: \(target.dependencies.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func metadata(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var targetDetail: some View {
        if let selected = selectedTarget {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: glyph(for: selected.target.productType))
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.target.displayName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(selected.target.productType.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    detailGrid(for: selected.target)
                    if !selected.target.dependencies.isEmpty {
                        dependencySection(for: selected, module: selected.module)
                    }
                    configurationsSection(for: selected)
                }
                .padding(14)
            }
        } else {
            ProjectEmptyDetailView(
                systemImage: "shippingbox",
                title: "Select a target",
                hint: "Pick a target on the left to see its product type, dependencies, and configurations."
            )
        }
    }

    private var selectedTarget: (module: ProjectModule, target: TargetSummary)? {
        guard let id = panel.selectedTargetID else { return nil }
        for module in model.modules {
            if let match = module.targets.first(where: { $0.id == id }) {
                return (module, match)
            }
        }
        return nil
    }

    @ViewBuilder
    private func detailGrid(for target: TargetSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row(label: "Product", value: target.productType.rawValue)
            row(
                label: "Platforms",
                value: target.platforms.isEmpty ? "—" : target.platforms.joined(separator: ", ")
            )
            row(label: "Deploy min", value: target.deploymentTarget ?? "—")
            row(label: "Bundle ID", value: target.bundleIdentifier ?? "—")
        }
    }

    @ViewBuilder
    private func dependencySection(for selected: (module: ProjectModule, target: TargetSummary), module: ProjectModule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dependencies")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(selected.target.dependencies, id: \.rawValue) { depID in
                let label = module.target(for: depID)?.displayName ?? String(depID.rawValue.prefix(10))
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.system(size: 12))
                }
            }
        }
    }

    @ViewBuilder
    private func configurationsSection(for selected: (module: ProjectModule, target: TargetSummary)) -> some View {
        let configCount = selected.module.configurations.filter { config in
            if case let .target(targetID) = config.scope, targetID == selected.target.id {
                return true
            }
            return false
        }.count
        let totalKeys = selected.module.configurations.reduce(0) { acc, config -> Int in
            if case let .target(targetID) = config.scope, targetID == selected.target.id {
                return acc + config.rawSettings.count
            }
            return acc
        }
        if configCount > 0 || totalKeys > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Build")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(configCount) configurations", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Label("\(totalKeys) target overrides", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                Button {
                    panel.selectedTargetID = selected.target.id
                    panel.activeTab = .buildSettings
                } label: {
                    Label("Open in Build Settings", systemImage: "arrow.right.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func glyph(for productType: TargetProductType) -> String {
        switch productType {
        case .application: return "app.fill"
        case .framework, .dynamicLibrary, .staticLibrary, .xcFramework: return "shippingbox"
        case .bundle: return "shippingbox.fill"
        case .unitTest, .uiTest: return "testtube.2"
        case .commandLineTool: return "terminal"
        case .appExtension: return "puzzlepiece.extension"
        case .watchApp, .watchExtension: return "applewatch"
        case .other: return "questionmark.square"
        }
    }
}
