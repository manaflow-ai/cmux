import Foundation
import SwiftUI
import Bonsplit

/// In-memory registry of `SidekickState` per terminal panel.
///
/// Kept separate from `TerminalPanel` because that type already
/// persists through a careful Codable / Bonsplit lifecycle path
/// (search "treeSnapshot" in Workspace.swift). Threading a new field
/// through that path is the right long-term fix, but for P2 we keep
/// the sidekick state in an ObservableObject keyed by panel UUID so
/// the wire-up does not perturb persistence or split routing.
///
/// Upgrade path: when `TerminalPanel` gains a `var sidekick:
/// SidekickState`, this store reduces to a thin façade — same API,
/// `subscript` simply forwards to the panel.
@MainActor
public final class SidekickStore: ObservableObject {
    public static let shared = SidekickStore()

    @Published private var states: [UUID: SidekickState] = [:]

    public subscript(panelID: UUID) -> SidekickState {
        get { states[panelID] ?? .default }
        set { states[panelID] = newValue }
    }

    public func binding(for panelID: UUID) -> Binding<SidekickState> {
        Binding(
            get: { self[panelID] },
            set: { self[panelID] = $0 })
    }

    /// Toggle from any caller (shortcut, command palette, context menu).
    public func toggle(panelID: UUID) {
        var s = self[panelID]
        s.isOpen.toggle()
        self[panelID] = s
    }
}

/// Wraps an existing terminal panel view with a collapsible sidekick.
///
/// Intentionally does **not** modify `TerminalPanelView`. The terminal
/// find UI is mounted in `GhosttySurfaceScrollView` at the AppKit
/// portal layer (see header comment in `TerminalPanelView.swift`),
/// and wrapping that NSViewRepresentable in an `HSplitView` risks
/// hiding the overlay. Instead, this container places the sidekick
/// as a *sibling* in an `HStack`, sized to a fixed leading fraction,
/// so the terminal view tree is unchanged when the sidekick is
/// collapsed.
///
/// Usage (call-site is the per-panel renderer, e.g. inside
/// `PanelContentView` for `.terminal` panels):
///
///     SidekickContainer(panelID: panel.id) {
///         TerminalPanelView(panel: panel, …)
///     }
@MainActor
public struct SidekickContainer<Content: View>: View {
    let panelID: UUID
    let content: () -> Content
    @StateObject private var store = SidekickStore.shared

    public init(panelID: UUID, @ViewBuilder content: @escaping () -> Content) {
        self.panelID = panelID
        self.content = content
    }

    public var body: some View {
        let state = store[panelID]
        Group {
            if state.isOpen {
                HStack(spacing: 0) {
                    content()
                    Divider()
                    SidekickWebViewContainer(
                        state: store.binding(for: panelID),
                        panelID: panelID)
                    .frame(minWidth: 220,
                           idealWidth: 360,
                           maxWidth: .infinity)
                }
            } else {
                content()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cmuxSidekickToggle)) { note in
            guard
                let info = note.userInfo,
                let pid = info["panelID"] as? UUID, pid == panelID
            else { return }
            store.toggle(panelID: panelID)
        }
    }
}
