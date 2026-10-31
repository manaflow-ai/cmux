public import CmuxNextDesign
import Foundation

/// Where a workspace row draws the brand mark of an agent running in it
/// (Debug Settings `sidebar.agentMark`). Harness rows show a mark beside the
/// title by default; the explicit off choice remains available for visual
/// comparison. The mark is a template tinted like the row's status.
public nonisolated enum SidebarAgentMarkVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// No mark: the row shows only its status glyph.
    case off
    /// The mark takes the status glyph's place while an agent runs, tinted with the
    /// waiting color when the agent waits for input.
    case replacesStatus
    /// A small mark before the title; the status glyph stays.
    case besideTitle

    public var tunableTitle: String {
        switch self {
        case .off: "Off"
        case .replacesStatus: "Replaces the status glyph"
        case .besideTitle: "Beside the title"
        }
    }
}
