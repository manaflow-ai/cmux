import Foundation

/// Emits shell-only, bounded telemetry admission for a wrapped Codex session.
public struct CodexToolHookProducer: Sendable {
    /// Creates the emitter for the wrapper's private spool protocol.
    public init() {}

    /// Wraps legacy admission with the per-session spool path.
    ///
    /// - Parameters:
    ///   event: Either `pre-tool-use` or `post-tool-use`.
    ///   fallback: The existing command for sessions without a forwarder.
    /// - Returns: A fail-open shell command that never launches a child on the spool path.
    public func command(event: String, fallback: String) -> String {
        guard event == "pre-tool-use" || event == "post-tool-use" else { return fallback }
        // exec replaces Codex's hook shell; it does not fork another process.
        // zsh's bundled sysread reads pipe chunks, unlike bash 3's byte-at-a-time
        // read builtin. No user startup files or external commands are loaded.
        let producer = #"""
        LC_ALL=C; export LC_ALL
        if [[ ${CMUX_CODEX_HOOKS_DISABLED:-} == 1 || -z ${CMUX_SURFACE_ID:-} ]]; then printf '{}\n'; exit 0; fi
        zmodload zsh/system || { printf '{}\n'; exit 0; }
        cmux_payload=''
        while (( ${#cmux_payload} <= 65536 )); do
            sysread -i 0 -s $((65537 - ${#cmux_payload})) cmux_chunk || break
            cmux_payload+=$cmux_chunk
        done
        if (( ${#cmux_payload} <= 65536 )); then
            umask 077; setopt noclobber
            cmux_slot="$CMUX_CODEX_FEED_DIR/$(( $$ % 32 ))"
            { printf '%s\n%s\0' '\#(event)' "$cmux_payload" > "$cmux_slot" && : > "$cmux_slot.ready"; } 2>/dev/null || :
        fi
        printf '{}\n'
        """#
        let quoted = "'" + producer.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -n \"${CMUX_CODEX_FEED_DIR:-}\" ]; then exec /bin/zsh -fc \(quoted); else \(fallback); fi"
    }
}
