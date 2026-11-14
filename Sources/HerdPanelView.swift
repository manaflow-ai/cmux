import SwiftUI

/// Herdr-inspired, cmux-native control surface for terminals and coding agents.
struct HerdPanelView: View {
    @Bindable var model: HerdPanelModel
    @EnvironmentObject private var tabManager: TabManager
    let onFocus: () -> Void
    let onFocusAnchorChange: (RightSidebarToolFocusAnchorView?) -> Void

    private var workspaceIDs: [UUID] { tabManager.tabs.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(
            RightSidebarToolFocusAnchor(onViewChange: onFocusAnchorChange)
                .frame(width: 0, height: 0)
        )
        .onAppear { model.attach(tabManager: tabManager) }
        .onChange(of: workspaceIDs) { _, _ in model.attach(tabManager: tabManager) }
        .sidebarAgentRuntimeObservations(
            ids: workspaceIDs,
            models: tabManager.tabs.map(\.sidebarAgentRuntimeObservation)
        ) { _ in
            model.refreshSnapshot()
        }
        .sidebarWorkspaceObservations(
            ids: workspaceIDs,
            workspaces: tabManager.tabs,
            debouncedInterval: Workspace.sidebarImmediateObservationCoalesceInterval
        ) { _ in
            model.refreshSnapshot()
        }
        .accessibilityIdentifier("HerdPanel")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(String(localized: "herd.title", defaultValue: "Herd"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            summaryChip(value: model.snapshot.agentCount, symbol: "person.2.fill", color: .secondary)
            summaryChip(value: model.snapshot.workingCount, symbol: "bolt.fill", color: .blue)
            summaryChip(value: model.snapshot.needsInputCount, symbol: "exclamationmark.bubble.fill", color: .orange)

            Spacer()

            Picker("", selection: $model.filter) {
                Text(String(localized: "feed.filter.all", defaultValue: "All")).tag(HerdPanelModel.Filter.all)
                Text(String(localized: "herd.filter.agents", defaultValue: "Agents")).tag(HerdPanelModel.Filter.agents)
                Text(String(localized: "feed.status.needsInput", defaultValue: "Needs input")).tag(HerdPanelModel.Filter.needsInput)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Button {
                model.refreshSnapshot()
                model.refreshTranscript()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "filePreview.refresh", defaultValue: "Refresh"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if model.filteredLanes.isEmpty {
            ContentUnavailableView {
                Label(
                    String(localized: "herd.empty.title", defaultValue: "No matching lanes"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            } description: {
                Text(String(localized: "herd.empty.description", defaultValue: "Start an agent in a terminal, or switch the filter to All."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.filteredLanes) { lane in
                            HerdLaneRow(
                                lane: lane,
                                isSelected: model.selectedLaneID == lane.id,
                                onSelect: {
                                    model.select(lane)
                                    onFocus()
                                }
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)

                if let lane = model.selectedLane {
                    HerdPanelDetailView(model: model, lane: lane)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func summaryChip(value: Int, symbol: String, color: Color) -> some View {
        Label("\(value)", systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}
