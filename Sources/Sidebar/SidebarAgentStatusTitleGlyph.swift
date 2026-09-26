import CmuxSidebar
import Foundation
import SwiftUI

/// One coding-agent status drawn as a glyph on the workspace title line when
/// `sidebar.compactAgentStatus` is on. Agent hooks report their lifecycle as
/// keyed status entries (`set_status claude_code Running --icon=bolt.fill`);
/// by default each one takes a full metadata row under the title. Compact mode
/// moves those agent-owned entries onto the title line as their tinted icon,
/// with the agent and status text in the tooltip. Other status entries stay
/// as metadata rows.
struct SidebarAgentStatusTitleGlyph: Equatable, Identifiable {
    /// The status entry key, e.g. `claude_code` or `codex`.
    let id: String
    let symbolName: String
    let colorHex: String?
    /// "Claude Code: Running"; also the accessibility label.
    let tooltip: String

    /// Upper bound on title-line glyphs so a busy workspace never squeezes
    /// the title away. Entries are display-ordered (priority, then newest),
    /// so the dropped ones are the least urgent.
    static let maxVisible = 3
    static let fallbackSymbolName = "circle.fill"

    private static let tooltipFormat = String(
        localized: "sidebar.agentStatus.glyph.tooltip",
        defaultValue: "%1$@: %2$@"
    )

    /// Splits display-ordered status entries into title-line glyphs (agent
    /// hook keys) and the entries that keep their metadata rows. With
    /// `compacts` off every entry stays a row.
    @MainActor
    static func partition(
        _ entries: [SidebarStatusEntry],
        compacts: Bool,
        isAgentKey: (String) -> Bool = AgentHibernationLifecycleStatusKeys.isAllowed
    ) -> (glyphs: [SidebarAgentStatusTitleGlyph], rows: [SidebarStatusEntry]) {
        guard compacts else { return ([], entries) }
        var glyphs: [SidebarAgentStatusTitleGlyph] = []
        var rows: [SidebarStatusEntry] = []
        for entry in entries {
            guard isAgentKey(entry.key) else {
                rows.append(entry)
                continue
            }
            guard glyphs.count < maxVisible else { continue }
            glyphs.append(SidebarAgentStatusTitleGlyph(entry: entry))
        }
        return (glyphs, rows)
    }

    init(id: String, symbolName: String, colorHex: String?, tooltip: String) {
        self.id = id
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.tooltip = tooltip
    }

    /// `sf:`-prefixed and bare SF Symbol names render as-is; `emoji:`/`text:`
    /// icons and unknown names fall back to a dot in the entry's color.
    @MainActor
    init(entry: SidebarStatusEntry) {
        let icon = entry.icon.map { $0.hasPrefix("sf:") ? String($0.dropFirst("sf:".count)) : $0 }
        self.init(
            id: entry.key,
            symbolName: RenderableSystemSymbol.normalized(icon) ?? Self.fallbackSymbolName,
            colorHex: entry.color,
            tooltip: String(
                format: Self.tooltipFormat,
                locale: .current,
                Self.agentDisplayName(forStatusKey: entry.key),
                entry.value
            )
        )
    }

    /// Human name for an agent status key (`claude_code` -> "Claude Code").
    static func agentDisplayName(forStatusKey key: String) -> String {
        if let definition = CmuxTaskManagerCodingAgentDefinition.builtIns.first(where: {
            $0.id == key || $0.directBasenames.contains(key)
        }) {
            return definition.displayName
        }
        return key
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// SwiftUI title-line rendering for the default sidebar list. Takes resolved
/// colors only; no store access below the lazy-list boundary.
struct SidebarAgentStatusTitleGlyphs: View {
    let glyphs: [SidebarAgentStatusTitleGlyph]
    let pointSize: CGFloat
    /// Selected rows flatten explicit colors to the selected foreground, like
    /// the metadata rows do, so blue "Running" does not vanish into the
    /// blue selection highlight.
    let isActive: Bool
    let activeColor: Color
    let fallbackColor: Color

    var body: some View {
        ForEach(glyphs) { glyph in
            CmuxSystemSymbolImage(
                magnified: glyph.symbolName,
                pointSize: pointSize,
                weight: .semibold,
                tint: tint(for: glyph)
            )
            .safeHelp(glyph.tooltip)
            .accessibilityLabel(glyph.tooltip)
        }
    }

    private func tint(for glyph: SidebarAgentStatusTitleGlyph) -> Color {
        if isActive { return activeColor }
        return glyph.colorHex.flatMap { Color(hex: $0) } ?? fallbackColor
    }
}
