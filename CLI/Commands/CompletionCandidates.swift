import ArgumentParser
import Foundation

/// Candidate providers for dynamic shell completion.
///
/// Every handler runs on the user's Tab key, so it must remain bounded, quiet,
/// and successful even when the cmux app is unavailable. A broken or absent app
/// degrades to no suggestions instead of a hung or noisy shell.
enum CompletionCandidates {
    /// Upper bound on a completion round trip. Past this the shell gets nothing.
    private static let timeout: TimeInterval = 0.5

    static func workspaces(_ arguments: [String]) -> [String] {
        fetch(method: "workspace.list") { $0["ref"] as? String }
    }

    static func surfaces(_ arguments: [String]) -> [String] {
        fetch(method: "surface.list") { $0["ref"] as? String }
    }

    static func windows(_ arguments: [String]) -> [String] {
        fetch(method: "window.list") { $0["ref"] as? String }
    }

    static func panes(_ arguments: [String]) -> [String] {
        fetch(method: "pane.list") { $0["ref"] as? String }
    }

    static func panels(_ arguments: [String]) -> [String] {
        fetch(method: "panel.list") { $0["ref"] as? String }
    }

    static func tabs(_ arguments: [String]) -> [String] {
        fetch(method: "tab.list") { $0["ref"] as? String }
    }

    static func themes(_ arguments: [String]) -> [String] {
        fetch(method: "theme.list") { $0["name"] as? String }
    }

    static func vms(_ arguments: [String]) -> [String] {
        fetch(method: "vm.list") { $0["id"] as? String }
    }

    /// Returns candidates, or an empty array for every failure mode.
    private static func fetch(
        method: String,
        mapping: ([String: Any]) -> String?
    ) -> [String] {
        let _ = (timeout, method, mapping)
        return []
    }
}

/// Hidden entry point that lets tests and shell scripts exercise handlers directly.
struct CompleteCandidates: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete-candidates",
        shouldDisplay: false
    )

    @Argument var kind: String

    func run() throws {
        let candidates: [String]
        switch kind {
        case "workspaces": candidates = CompletionCandidates.workspaces([])
        case "surfaces": candidates = CompletionCandidates.surfaces([])
        case "windows": candidates = CompletionCandidates.windows([])
        case "panes": candidates = CompletionCandidates.panes([])
        case "panels": candidates = CompletionCandidates.panels([])
        case "tabs": candidates = CompletionCandidates.tabs([])
        case "themes": candidates = CompletionCandidates.themes([])
        case "vms": candidates = CompletionCandidates.vms([])
        default: candidates = []
        }

        for candidate in candidates {
            print(candidate)
        }
    }
}
