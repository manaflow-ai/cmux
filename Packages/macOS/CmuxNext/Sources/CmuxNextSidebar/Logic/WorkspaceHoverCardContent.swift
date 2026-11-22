import CmuxNextIcons
import CmuxNextResources
import Foundation

/// What the workspace hover card says (Leo 2026-10-08, Codex parity): a
/// title row (the name, a kind or host icon, the relative age) and one row
/// per meaningful fact, each with an icon. CPU and memory show as one line,
/// and only when notable.
struct WorkspaceHoverCardContent: Equatable {
    struct Fact: Equatable {
        var icon: IconName
        var text: String
    }

    var title: String
    var icon: IconName
    /// How long ago the workspace was last active ("4w"); nil without activity.
    var age: String?
    var facts: [Fact]

    /// CPU of at least half a core, or memory of at least 1 GB, is worth a line.
    static let notableCPU = 0.5
    static let notableMemoryBytes: UInt64 = 1 << 30

    static func make(_ workspace: SidebarWorkspace, machine: SidebarMachine?, now: Date) -> Self {
        let remote = machine.flatMap { $0.kind == .local ? nil : $0 }
        var facts: [Fact] = []
        if let folder = workspace.directory.flatMap({ $0.isEmpty ? nil : folderName($0) }) { facts.append(Fact(icon: .folder, text: folder)) }
        if let branch = workspace.branch, !branch.isEmpty { facts.append(Fact(icon: .gitBranch, text: branch)) }
        if let pr = workspace.pullRequest, !pr.isEmpty { facts.append(Fact(icon: .gitPullrequest, text: pr)) }
        if let remote { facts.append(Fact(icon: hostIcon(remote), text: remote.name)) }
        return WorkspaceHoverCardContent(
            title: workspace.title, icon: remote.map(hostIcon) ?? workspace.kind.iconName,
            age: workspace.lastActivity.flatMap { age(since: $0, now: now) }, facts: facts)
    }

    /// The one resource line, or nil while the workspace is quiet.
    static func resourceLine(_ report: ResourceReport?) -> String? {
        guard let total = report?.total,
              (total.cpu ?? 0) >= notableCPU || total.memoryBytes >= notableMemoryBytes else { return nil }
        return ResourceFormat.line(total)
    }

    /// The folder's own name: "~/Projects/site" reads "site", and the home
    /// folder reads as its name, not "~".
    static func folderName(_ directory: String) -> String {
        let path = (directory as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private static func hostIcon(_ machine: SidebarMachine) -> IconName {
        switch machine.kind {
        case .local: .machineLocal
        case .cloud: .cloud
        case .ssh, .server: .machineRemote
        }
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "4w", "3d", "5h", "12m"; nil under a minute.
    static func age(since date: Date, now: Date) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return nil }
        return ageFormatter.string(from: seconds)
    }
}
