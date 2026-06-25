import CMUXProjectModel
import CmuxPanes
import SwiftUI

/// Schemes tab inside ``ProjectPanelView``.
///
/// Renders shared and per-user schemes as a single table with a small
/// "shared / personal" badge, plus a detail panel for the selected scheme
/// listing its run / test / profile / archive targets, launch arguments,
/// and environment variables.
struct ProjectSchemesTabView: View {
    @ObservedObject var panel: ProjectPanel
    let model: ProjectModel

    var body: some View {
        HSplitView {
            schemeList
                .frame(minWidth: 280, idealWidth: 360, maxHeight: .infinity)
            detail
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var schemeList: some View {
        let entries: [(module: ProjectModule, scheme: SchemeSummary, compositeID: String)] = model.modules.flatMap { module in
            module.schemes.map { scheme in
                (module: module, scheme: scheme, compositeID: "\(module.id.rawValue)|\(scheme.name)")
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.compositeID) { entry in
                    schemeRow(entry.scheme, module: entry.module)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func schemeRow(_ scheme: SchemeSummary, module: ProjectModule) -> some View {
        let isSelected = panel.selectedSchemeName == scheme.name
        Button(action: { panel.selectedSchemeName = scheme.name }) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(scheme.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(scheme.isShared ? "shared" : "personal")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill((scheme.isShared ? Color.accentColor : Color.orange).opacity(0.18))
                            )
                            .foregroundStyle(scheme.isShared ? Color.accentColor : Color.orange)
                    }
                    HStack(spacing: 8) {
                        if !scheme.runTargetIDs.isEmpty {
                            Text("run: \(targetNames(for: scheme.runTargetIDs, in: module))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if !scheme.testTargetIDs.isEmpty {
                            Text("test: \(scheme.testTargetIDs.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = selectedScheme {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label(selected.scheme.name, systemImage: "play.rectangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(selected.scheme.isShared ? "shared" : "personal")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill((selected.scheme.isShared ? Color.accentColor : Color.orange).opacity(0.18))
                            )
                            .foregroundStyle(selected.scheme.isShared ? Color.accentColor : Color.orange)
                        Spacer()
                    }
                    row(label: "Visibility", value: selected.scheme.isShared ? "Shared" : "Personal (current user)")
                    if !selected.scheme.runTargetIDs.isEmpty {
                        row(label: "Run target", value: targetNames(for: selected.scheme.runTargetIDs, in: selected.module))
                    }
                    if !selected.scheme.testTargetIDs.isEmpty {
                        row(label: "Test targets", value: targetNames(for: selected.scheme.testTargetIDs, in: selected.module))
                    }
                    if let profile = selected.scheme.profileTargetID {
                        row(label: "Profile target", value: targetNames(for: [profile], in: selected.module))
                    }
                    if let archive = selected.scheme.archiveTargetID {
                        row(label: "Archive target", value: targetNames(for: [archive], in: selected.module))
                    }
                    if !selected.scheme.launchArguments.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch arguments")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(selected.scheme.launchArguments, id: \.self) { arg in
                                Text(arg)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !selected.scheme.environmentVariables.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Environment")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(selected.scheme.environmentVariables.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                                Text("\(entry.key) = \(entry.value)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(14)
            }
        } else {
            ProjectEmptyDetailView(
                systemImage: "play.rectangle",
                title: "Select a scheme",
                hint: "Pick a scheme on the left to inspect its run / test / profile / archive targets and launch settings."
            )
        }
    }

    private var selectedScheme: (module: ProjectModule, scheme: SchemeSummary)? {
        guard let name = panel.selectedSchemeName else { return nil }
        for module in model.modules {
            if let match = module.schemes.first(where: { $0.name == name }) {
                return (module, match)
            }
        }
        return nil
    }

    private func targetNames(for ids: [TargetID], in module: ProjectModule) -> String {
        ids.map { id in module.target(for: id)?.displayName ?? String(id.rawValue.prefix(8)) }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }
}
