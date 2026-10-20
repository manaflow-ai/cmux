#if DEBUG
public import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources

/// DEBUG ONLY: the workspace hover card in each of its kinds over fixture data, for the hover card
/// gallery (`debug.hover_card_gallery`, the macOS tour's `hover-card` shots; Leo 2026-10-19, the
/// Codex sidebar card and Claude desktop's PR list). The words are fixture data, like a mock's.
public struct WorkspaceHoverCardGallery {
    public init() {}
    /// Each state's name and its card on the overlay glass, configured; resources sampled a few
    /// times so the CPU bars show.
    @MainActor public static func cards(now: Date = Date()) -> [(name: String, view: NSView)] {
        typealias Fact = WorkspaceHoverCardContent.Fact
        let agent = Fact(icon: .agentChat, text: "Codex · gpt-6.1-sol", kind: "agent")
        let folder = Fact(icon: .folder, text: "cmux", kind: "folder")
        let branch = Fact(icon: .gitBranch, text: "feat/shared-hover-card", kind: "branch")
        let reply = Fact(icon: .agentChatList, text: "Done: the tab and session cards share one row now, with the PR status in color.",
                         lines: 2, kind: Fact.lastReplyKind)
        let context = Fact(icon: .contextUsage, text: "Context", kind: "context", accessory: .ring(0.62, tone: .secondary))
        func pr(_ status: String, _ tone: HoverCardTone, adds: Int, dels: Int) -> Fact {
            Fact(icon: .gitPullrequest, text: "cmux #22231", kind: "pullRequest", status: status, statusTone: tone,
                 additions: adds, deletions: dels)
        }
        let machine = Fact(icon: .machineRemote, text: "air-blue", kind: "machine", accessory: .dot(.danger))
        let offline = Fact(icon: .statusDisconnected, text: "Remote environment is offline", kind: "machineStatus", ink: .danger)
        let states: [(String, WorkspaceHoverCardContent, [Double])] = [
            ("Agent running", WorkspaceHoverCardContent(
                title: "Make the hover cards look like Codex's", icon: .agentChat, age: "3m",
                facts: [agent, context, folder, branch, pr("Checks running", .attention, adds: 412, dels: 96), reply],
                activity: .working, activitySince: now.addingTimeInterval(-192)), [0.4, 0.9, 1.3, 1.8, 2.2, 1.6, 2.4]),
            ("Agent idle", WorkspaceHoverCardContent(
                title: "Fix the session hover card", icon: .agentChat, age: "1d",
                facts: [agent, folder, branch, reply]), []),
            ("Remote offline", WorkspaceHoverCardContent(
                title: "Deploy the docs", icon: .machineRemote, age: "2h",
                facts: [folder, machine, offline]), []),
            ("PR conflict", WorkspaceHoverCardContent(
                title: "Sidebar rows badge their logo's corner", icon: .agentChat, age: "5h",
                facts: [folder, branch, pr("Conflict", .attention, adds: 88, dels: 31),
                        pr("Checks failed", .danger, adds: 88, dels: 31)]), []),
            ("PR merged", WorkspaceHoverCardContent(
                title: "Overlays are themed Liquid Glass", icon: .agentChat, age: "4w",
                facts: [folder, branch, pr("Merged", .merged, adds: 69, dels: 32)]), []),
        ]
        return states.map { name, content, cpu in
            let card = WorkspaceHoverCardView()
            card.configure(content, now: now)
            for value in cpu {
                card.setResources(ResourceReport(total: ResourceUsage(cpu: value, memoryBytes: 2_300 << 20), processCount: 6))
            }
            return (name, HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() })
        }
    }
}
#endif
