public import CmuxNextDesign
public import Foundation

/// The All chats row design (TEMPORARY Debug Settings picker `sidebar.allChats.design`, cx-xub5):
/// Lawrence tries the three minimal gallery designs in a tagged build and votes; then the picker
/// and the two losers are deleted.
public nonisolated enum SidebarChatsDesign: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The harness glyph, then the title.
    case quiet
    /// The title, then a faint age on the right; no glyph.
    case age
    /// The title · its project; no glyph.
    case project

    public var tunableTitle: String {
        switch self {
        case .quiet: "Quiet (glyph + title)"
        case .age: "Age (title + age)"
        case .project: "Project (title · project)"
        }
    }

    public static let tunable = Tunable<SidebarChatsDesign>.choice(
        "sidebar.allChats.design", .sidebar, "All chats design",
        help: "TEMPORARY (cx-xub5 vote): how All chats rows draw. Quiet, Age or Project.",
        default: .age, code: "SidebarChatsDesign.tunable")

    /// The row's trailing text in this design: the age (`updatedAt` against `now`), the project
    /// folder's name, or nothing.
    func meta(updatedAt: Date?, folder: String?, now: Date) -> String? {
        switch self {
        case .quiet: return nil
        case .age: return updatedAt.map { Self.age(from: $0, to: now) }
        case .project: return folder.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// "2m", "3h", "2d" (localized, one unit).
    static func age(from date: Date, to now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day, .weekOfMonth]
        return formatter.string(from: max(60, now.timeIntervalSince(date))) ?? ""
    }
}
