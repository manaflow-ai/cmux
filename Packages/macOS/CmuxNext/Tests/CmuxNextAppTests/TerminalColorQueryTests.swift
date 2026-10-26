import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Testing

/// Codex tints its composer row from the terminal background it reads with
/// an OSC 11 query (`ESC ] 11 ; ? BEL`). In cmux-next the cmux-tui daemon
/// answers those queries (the app's Ghostty surface is a mirror whose replies
/// are suppressed), so the daemon must answer with the colors the app paints.
/// The app never told the daemon its theme: the daemon answered from its own
/// read of the Ghostty config files (cmux-next's default theme and light/dark
/// switching unknown to it), or not at all when that read timed out, and
/// Codex then drew no composer band.
///
/// The daemon here reads a Ghostty config with a background no app theme
/// uses, so only the app's colors can make the reply match.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TerminalColorQueryTests {
    /// The background the daemon's own Ghostty config names.
    static let daemonConfigBackground = "#0a0b0c"

    @Test func osc11AnswersTheBackgroundTheAppPaints() async throws {
        let expected = try #require(GhosttyRuntime.startedForTests().themeColors, "the app's Ghostty config did not load")
        let reply = Self.reply(expected.background)
        #expect(reply != "rgb:0a0a/0b0b/0c0c", "the app's theme uses the daemon config's background; pick another")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-oscq-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let ghostty = home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: ghostty, withIntermediateDirectories: true)
        try "background = \(Self.daemonConfigBackground)\nforeground = #0d0e0f\n"
            .write(to: ghostty.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("osc11.txt")

        try await PasswordManagerRouteTests.withApp(home: home.path) { _, connection in
            let workspace = try await connection.createWorkspace(name: "osc-probe")
            _ = try await connection.createTerminal(in: workspace.key, cwd: root.path, argv: ["/usr/bin/perl", "-e", Self.probe, out.path],
                                                    size: CellSize(cols: 80, rows: 24))
            // The probe asks again every 250 ms, so a reply written after the app pushes its colors counts.
            try await PasswordManagerRouteTests.until({ Self.lastReply(out) == reply }, within: .seconds(45),
                                                      report: { "want \(reply); probe wrote: \((try? String(contentsOf: out, encoding: .utf8)) ?? "no file")" })
        }
    }

    /// `rgb:rrrr/gggg/bbbb`, the form Ghostty and cmux-tui answer OSC 11 in.
    static func reply(_ color: GhosttyThemeColors.RGB) -> String {
        String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", color.r, color.r, color.g, color.g, color.b, color.b)
    }

    static func lastReply(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }

    /// Puts its terminal in raw mode, sends OSC 11 queries for 15 s, and writes each
    /// answer's color (or `none`) to the file named by its argument, one per line,
    /// after a `started` line. An error goes to the file too.
    static let probe = #"""
    my $out = shift;
    sub note { open(my $fh, ">>", $out); print $fh "$_[0]\n"; close($fh); }
    note("started");
    $SIG{__DIE__} = sub { note("error: $_[0]"); };
    system("stty raw -echo") == 0 or note("error: stty $?");
    $| = 1;
    for my $i (1..60) {
        syswrite(STDOUT, "\e]11;?\a");
        my ($buf, $rin) = ("", "");
        vec($rin, fileno(STDIN), 1) = 1;
        while (select(my $r = $rin, undef, undef, 0.25) > 0) {
            last unless sysread(STDIN, $buf, 64, length $buf);
            last if $buf =~ /\a|\e\\/;
        }
        my ($color) = $buf =~ /\]11;(rgb:[0-9a-f\/]+)/;
        note($color // "none");
    }
    sleep 30;
    """#
}
