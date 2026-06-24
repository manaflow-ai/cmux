#if canImport(UIKit) && DEBUG
import Foundation

/// Sample agent-session transcripts (ANSI) used to populate the standalone
/// terminal preview for App Store screenshots. Selected via
/// `CMUX_UITEST_TERMINAL_TRANSCRIPT` (claude | codex | opencode | pi). Each is
/// a realistic, self-contained session that shows a different coding agent
/// running through the cmux terminal.
enum TerminalPreviewTranscripts {
    private static let esc = "\u{1B}"
    private static let reset = "\u{1B}[0m"
    private static let dim = "\u{1B}[2m"
    private static let green = "\u{1B}[1;32m"
    private static let cyan = "\u{1B}[36m"
    private static let magenta = "\u{1B}[1;35m"
    private static let yellow = "\u{1B}[33m"
    private static let blue = "\u{1B}[1;34m"

    private static func render(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    static func transcript(named name: String) -> Data {
        switch name.lowercased() {
        case "codex": return codex
        case "opencode": return opencode
        case "pi": return pi
        default: return claude
        }
    }

    private static var prompt: String { "\(green)❯\(reset)" }

    static let claude = render([
        "\(dim)~/projects/app\(reset)  \(cyan)main\(reset)",
        "\(prompt) claude \(dim)\"add a dark mode toggle\"\(reset)",
        "",
        "\(magenta)●\(reset) I'll add a dark mode toggle to Settings.",
        "  \(dim)Reading\(reset) SettingsView.swift",
        "  \(green)✓\(reset) Added \(cyan)@AppStorage(\"isDarkMode\")\(reset)",
        "  \(green)✓\(reset) Wired \(cyan)Toggle\(reset) into the General section",
        "  \(green)✓\(reset) Applied \(cyan).preferredColorScheme\(reset)",
        "",
        "  \(green)Build succeeded.\(reset) 2 files changed.",
        "",
        "\(prompt) ",
    ])

    static let codex = render([
        "\(dim)~/projects/api\(reset)  \(cyan)main\(reset)",
        "\(prompt) codex \(dim)\"fix the failing auth test\"\(reset)",
        "",
        "\(blue)›\(reset) Reproducing \(cyan)test_login_expired\(reset)…",
        "  \(yellow)•\(reset) token TTL compared in ms, not s",
        "  \(dim)Patching\(reset) auth/session.ts",
        "  \(green)✓\(reset) 1 file changed, 3 insertions",
        "  \(green)✓\(reset) 42 passed, 0 failed",
        "",
        "\(prompt) ",
    ])

    static let opencode = render([
        "\(dim)~/projects/web\(reset)  \(cyan)main\(reset)",
        "\(prompt) opencode \(dim)\"use a reducer for the cart\"\(reset)",
        "",
        "\(magenta)▌\(reset) Planning the refactor…",
        "  \(green)→\(reset) components/Cart.tsx",
        "  \(green)→\(reset) state/cartReducer.ts",
        "  \(green)✓\(reset) Extracted 6 actions, removed 80 lines",
        "  \(green)✓\(reset) \(cyan)tsc --noEmit\(reset) clean",
        "",
        "\(prompt) ",
    ])

    static let pi = render([
        "\(dim)~/infra\(reset)  \(cyan)main\(reset)",
        "\(prompt) pi \(dim)\"scale the worker pool to 8\"\(reset)",
        "",
        "\(magenta)π\(reset) Deploying…",
        "  \(green)✓\(reset) workers \(yellow)3 → 8\(reset)",
        "  \(green)✓\(reset) health checks green",
        "  \(green)✓\(reset) rollout complete in 12s",
        "",
        "\(prompt) ",
    ])
}
#endif
