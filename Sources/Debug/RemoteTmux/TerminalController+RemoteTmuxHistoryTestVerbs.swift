// DEBUG-only `remote.tmux.test_exec` verbs for the full-history UI test, split out of
// TerminalController+RemoteTmuxTestSupport.swift. Like the rest of that grammar, each
// verb expands to a tmux argv the app owns; nothing the test sends reaches a shell.

#if DEBUG
import Foundation

extension TerminalController {
    /// The argv for `set-history-limit` and `print-history`, or nil for anything else
    /// or for arguments outside their grammar.
    /// - Parameter args: The verb and its arguments.
    /// - Parameter isAtom: The test grammar's check for a target or name.
    nonisolated static func remoteTmuxHistoryTestCommandArguments(
        _ args: [String],
        isAtom: (String) -> Bool
    ) -> [String]? {
        switch args.first {
        case "set-history-limit":
            // Applies to panes created afterward; the full-history test needs more
            // rows than tmux's default 2,000.
            guard args.count == 2, let rows = Int(args[1]), (1...200_000).contains(rows) else { return nil }
            return ["set-option", "-g", "history-limit", String(rows)]
        case "print-history":
            // `print-history -t <pane> <rows> plain|dense`: types an app-owned loop
            // that prints numbered rows. `dense` gives every cell its own 24-bit
            // foreground and ends each row with ` L<n>`.
            guard args.count == 5, args[1] == "-t", isAtom(args[2]),
                  let rows = Int(args[3]), (1...100_000).contains(rows) else { return nil }
            switch args[4] {
            case "plain":
                return ["send-keys", "-t", args[2], "clear; seq 1 \(rows)", "Enter"]
            case "dense":
                let script = "perl -e 'for $i (1..\(rows)) { $s = \"\"; for $c (1..60) { "
                    + "$s .= sprintf(\"\\e[38;2;%d;%d;%dm%s\", $c, $i % 256, ($c * $i) % 256, "
                    + "chr(97 + ($c + $i) % 26)) } print \"$s\\e[0m L$i\\n\" }'"
                return ["send-keys", "-t", args[2], "clear; " + script, "Enter"]
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
#endif
