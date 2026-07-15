#if DEBUG
import SwiftUI

/// Renders Phosphor's status-sorted workspace attention queue.
struct PhosphorHubScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var rowsVisible = false
    private let typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        List {
            Section {
                ForEach(sortedWorkspaces(theme: theme)) { workspace in
                    PhosphorWorkspaceRow(workspace: workspace)
                        .opacity(rowsVisible ? 1.0 : 0.0)
                        .offset(y: reduceMotion || rowsVisible ? 0 : 4)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(theme.bg0)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(theme.isNeedsYou(workspace.state) ? "Approve" : "Reply", action: {})
                                .tint(theme.isNeedsYou(workspace.state) ? theme.statusNeedsYou : theme.accent)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button("Mark read", action: {})
                                .tint(theme.bg2)
                        }
                }
            } header: {
                Text(statusSummary)
                    .font(typography.monoCaptionMedium)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(theme.bg1)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.hairline).frame(height: 1)
                    }
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg0.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PhosphorCommandBar(showsApprove: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.18)) {
                rowsVisible = true
            }
        }
    }

    private func sortedWorkspaces(theme: PhosphorTheme) -> [GalleryWorkspaceFixture] {
        DesignGalleryFixtures.workspaces.sorted {
            theme.statusRank($0.state) < theme.statusRank($1.state)
        }
    }

    /// The fixture-derived status counts, in attention order, nonzero only.
    private var statusSummary: String {
        let labels: [(GalleryAgentState, String)] = [
            (.needsYou, "needs you"), (.failed, "failed"), (.running, "running"),
            (.done, "done"), (.idle, "idle"),
        ]
        return labels.compactMap { state, label in
            let count = DesignGalleryFixtures.workspaces.filter { $0.state == state }.count
            return count > 0 ? "\(count) \(label)" : nil
        }
        .joined(separator: " · ")
    }
}
#endif
