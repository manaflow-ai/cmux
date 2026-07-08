import AppKit
import SwiftUI

/// Debug explorer for the per-agent sidebar row presentation: eight variants
/// switchable live from Debug > "Agent Rows Style…", persisted in
/// UserDefaults. This is a dogfood decision aid; once a winner is picked the
/// losing variants get deleted and the store collapses to a constant.
enum SidebarAgentRowsVariant: String, CaseIterable, Identifiable {
    case graphite
    case belowAccordion
    case belowFlat
    case belowTree
    case belowChips
    case inCardRows
    case inCardCompact
    case globalSection

    static let userDefaultsKey = "sidebarAgentRowsVariantDebug"

    var id: String { rawValue }

    var isInCard: Bool { self == .inCardRows || self == .inCardCompact }

    var displayName: String {
        switch self {
        case .graphite:
            return String(localized: "debug.agentRows.variant.graphite", defaultValue: "Graphite prototype (picked)")
        case .belowAccordion:
            return String(localized: "debug.agentRows.variant.belowAccordion", defaultValue: "Below card · accordion")
        case .belowFlat:
            return String(localized: "debug.agentRows.variant.belowFlat", defaultValue: "Below card · flat rows")
        case .belowTree:
            return String(localized: "debug.agentRows.variant.belowTree", defaultValue: "Below card · tree guide")
        case .belowChips:
            return String(localized: "debug.agentRows.variant.belowChips", defaultValue: "Below card · chips")
        case .inCardRows:
            return String(localized: "debug.agentRows.variant.inCardRows", defaultValue: "In card · rows")
        case .inCardCompact:
            return String(localized: "debug.agentRows.variant.inCardCompact", defaultValue: "In card · compact line")
        case .globalSection:
            return String(localized: "debug.agentRows.variant.globalSection", defaultValue: "Global Agents section (sidebar bottom)")
        }
    }

    var detail: String {
        switch self {
        case .graphite:
            return String(localized: "debug.agentRows.variant.graphite.detail", defaultValue: "Graphite selection card, in-card accordion, accent bar on the active (focused) agent.")
        case .belowAccordion:
            return String(localized: "debug.agentRows.variant.belowAccordion.detail", defaultValue: "Summary header folds the rows; each row is its own button.")
        case .belowFlat:
            return String(localized: "debug.agentRows.variant.belowFlat.detail", defaultValue: "Always-expanded rows, no header.")
        case .belowTree:
            return String(localized: "debug.agentRows.variant.belowTree.detail", defaultValue: "Rows hang off a tree guide line under the workspace.")
        case .belowChips:
            return String(localized: "debug.agentRows.variant.belowChips.detail", defaultValue: "Wrapping icon chips, one per agent.")
        case .inCardRows:
            return String(localized: "debug.agentRows.variant.inCardRows.detail", defaultValue: "Rows embedded inside the workspace card.")
        case .inCardCompact:
            return String(localized: "debug.agentRows.variant.inCardCompact.detail", defaultValue: "One dense line of brand icons and state dots in the card.")
        case .globalSection:
            return String(localized: "debug.agentRows.variant.globalSection.detail", defaultValue: "No per-workspace rows; one Agents list at the sidebar bottom, grouped by workspace.")
        }
    }
}

/// Singleton the row containers observe. It only mutates when the user picks
/// a variant in the lab window, so the extra invalidation is bounded; this is
/// a deliberate, temporary exception to the sidebar snapshot-boundary rule
/// while the presentation is being chosen.
@MainActor
final class SidebarAgentRowsVariantStore: ObservableObject {
    static let shared = SidebarAgentRowsVariantStore()

    @Published var variant: SidebarAgentRowsVariant {
        didSet {
            UserDefaults.standard.set(variant.rawValue, forKey: SidebarAgentRowsVariant.userDefaultsKey)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: SidebarAgentRowsVariant.userDefaultsKey)
        variant = raw.flatMap(SidebarAgentRowsVariant.init(rawValue:)) ?? .belowAccordion
    }
}

@MainActor
final class AgentRowsVariantLabWindowController: ReleasingWindowController {
    static let shared = AgentRowsVariantLabWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 430),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.agentRows.window.title", defaultValue: "Agent Rows Style")
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("cmux.agentRowsVariantLab")
        window.center()
        window.contentView = NSHostingView(rootView: AgentRowsVariantLabView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct AgentRowsVariantLabView: View {
    @ObservedObject private var store = SidebarAgentRowsVariantStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "debug.agentRows.window.caption",
                defaultValue: "Switches the per-agent sidebar rows live. The choice persists across relaunch."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            ForEach(SidebarAgentRowsVariant.allCases) { variant in
                Button {
                    store.variant = variant
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: store.variant == variant ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(store.variant == variant ? Color.accentColor : .secondary)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(variant.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(variant.detail)
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380, alignment: .topLeading)
    }
}

/// The `globalSection` variant: one Agents list at the bottom of the sidebar,
/// grouped by workspace. Reads live workspace state directly; acceptable only
/// because it renders exclusively while this debug variant is selected. Owns
/// its TabManager observation so the host (the sidebar footer) does not
/// re-render on TabManager changes; when another variant is selected the
/// re-evaluated body is a single enum comparison.
struct SidebarGlobalAgentsSection: View {
    let fontScale: CGFloat

    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var store = SidebarAgentRowsVariantStore.shared

    private func focus(workspaceId: UUID, panelId: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        tabManager.selectedTabId = workspaceId
        tab.focusPanel(panelId)
    }

    var body: some View {
        if store.variant == .globalSection {
            let groups = tabManager.tabs.compactMap { tab -> (workspaceId: UUID, title: String, rows: [SidebarAgentStatusRow])? in
                let rows = tab.sidebarAgentStatusRows()
                guard !rows.isEmpty else { return nil }
                return (tab.id, tab.title, rows)
            }
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "sidebar.agentStatus.globalSection.header", defaultValue: "Agents"))
                        .cmuxFont(size: 10 * fontScale, weight: .semibold)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    ForEach(groups, id: \.workspaceId) { group in
                        Text(group.title)
                            .cmuxFont(size: 9 * fontScale, weight: .medium)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                        ForEach(group.rows) { row in
                            SidebarAgentStatusEntryRowView(
                                row: row,
                                fontScale: fontScale,
                                layout: .nameFirst,
                                onFocusPanel: { panelId in focus(workspaceId: group.workspaceId, panelId: panelId) }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}
