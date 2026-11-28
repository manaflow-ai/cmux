public import Foundation

/// How a Make cmux Yours walk ended (`cmux_window_rules::walk_split::Ending`).
public nonisolated enum IntroWalkEnding: String, Sendable, Codable, Equatable {
    case started, completed, skipped
}

/// Make cmux Yours as a split (cmux-window-rules walk_split.rs): this install's bundle (an arm per
/// contested screen, assigned once from the install key) and the record of each walk's start and
/// end against it, so a contested step is judged on the walks that saw each arm (Leo,
/// ask-b9fd9d4f9c: "i think we can hill climb user-facing decisions"). Every slot ships with its
/// split off, so every install's bundle is today's walk (`wb1-000000`) until a slot is raised.
@MainActor
public protocol IntroWalkSplitSource: AnyObject {
    /// This install's bundle id (`wb1-` then each slot's arm index); nil when Rust does not answer.
    func bundle() -> String?
    /// Logs one walk's start or end against `bundle`. `screen`: the walk's screen index at the end.
    func record(bundle: String, ending: IntroWalkEnding, screen: Int)
}
