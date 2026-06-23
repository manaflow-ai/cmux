import Foundation

/// Installs a tiny status-reporting hook into a remote host's Claude Code and
/// Codex configuration so an agent running inside a `cmux ssh-tmux` mirror reports
/// running/working/idle (+ model) back to cmux's left sidebar — Option C in
/// `docs/investigations/remote-agent-status-sidebar.md`.
///
/// The hook runs entirely on the remote and is dependency-free: on each lifecycle
/// event it runs `tmux set -t "$TMUX_PANE" @cmux_agent '<json>'`. cmux already
/// subscribes to `#{@cmux_agent}` per pane over the live `tmux -CC` control stream
/// (``RemoteTmuxControlConnection/subscribePaneAgent(paneId:)``), so the value
/// arrives as a `%subscription-changed` line — **no remote cmux CLI, no socket, no
/// reverse relay, no auth**. The hook self-disables when `$TMUX_PANE` is unset
/// (i.e. the agent isn't running inside tmux), so installing it is harmless
/// outside the mirror.
///
/// This type only *builds* the shell scripts + config edits; the remote write is
/// performed over ``RemoteTmuxSSHTransport`` by the caller. Everything here is pure
/// and unit-tested.
enum RemoteTmuxAgentHookInstaller {
    /// The shared shell hook body, parameterized by the agent label and the state.
    /// Reads the event JSON on stdin (Claude/Codex both feed it there), best-effort
    /// extracts a model id, and publishes the status into the pane's `@cmux_agent`
    /// option. Always prints `{}` last so a blocking hook gets valid stdout.
    ///
    /// - `agent`: the label cmux maps back to a provider (`claude` / `codex`).
    /// - `state`: the lifecycle word (`running` / `working` / `idle`).
    static func hookScript(agent: String, state: String) -> String {
        // Publishes two pane-scoped tmux options the cmux mirror subscribes to:
        //   @cmux_agent — {agent,state,model?}: written synchronously (cheap).
        //   @cmux_git   — {branch,dirty,pr?}:   written in a DETACHED background
        //                 subshell because `git` + `gh pr view` can be slow, and a
        //                 hook must never delay the agent's own event.
        // Both `tmux set` are scoped to $TMUX_PANE so they land on the agent's own
        // pane; outside tmux ($TMUX_PANE empty) everything is skipped. Always
        // prints `{}` last so a blocking hook gets valid stdout.
        """
        IN=$(cat 2>/dev/null); \
        if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then \
        MODEL=$(printf '%s' "$IN" | grep -o '\"model\":\"[^\"]*\"' | tail -1 | sed 's/.*\"model\":\"//; s/\"$//'); \
        if [ -n "$MODEL" ]; then \
        tmux set -t "$TMUX_PANE" @cmux_agent "{\\"agent\\":\\"\(agent)\\",\\"state\\":\\"\(state)\\",\\"model\\":\\"$MODEL\\"}" >/dev/null 2>&1; \
        else \
        tmux set -t "$TMUX_PANE" @cmux_agent "{\\"agent\\":\\"\(agent)\\",\\"state\\":\\"\(state)\\"}" >/dev/null 2>&1; \
        fi; \
        ( P="$TMUX_PANE"; \
        B=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); \
        if [ -n "$B" ] && [ "$B" != "HEAD" ]; then \
        if git diff --quiet --ignore-submodules HEAD >/dev/null 2>&1; then D=0; else D=1; fi; \
        PR=$(gh pr view --json number,state,url -q '\",\\"pr\\":{\\"number\\":\"+(.number|tostring)+\",\\"state\\":\\"\"+.state+\"\\",\\"url\\":\\"\"+.url+\"\\"}\"' 2>/dev/null); \
        tmux set -t "$P" @cmux_git "{\\"branch\\":\\"$B\\",\\"dirty\\":$D$PR}" >/dev/null 2>&1; \
        fi ) >/dev/null 2>&1 </dev/null & \
        fi; \
        printf '{}'
        """
    }

    /// Marker so cmux can recognize (and replace/remove) its own remote hook
    /// entries without disturbing the user's other hooks.
    static let marker = "cmux-remote-agent-status"

    // MARK: - Claude (~/.claude/settings.json)

    /// The `hooks` object cmux merges into the remote `~/.claude/settings.json`.
    /// SessionStart/UserPromptSubmit → working/running; Stop → idle.
    static func claudeHooksObject() -> [String: Any] {
        func entry(_ state: String) -> [String: Any] {
            [
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": hookScript(agent: "claude", state: state),
                    "timeout": 5,
                    "_cmux": marker,
                ]],
            ]
        }
        return [
            "SessionStart": [entry("running")],
            "UserPromptSubmit": [entry("working")],
            "Stop": [entry("idle")],
        ]
    }

    /// Builds the remote shell command that merges cmux's hooks into
    /// `~/.claude/settings.json` (creating it if absent), preserving any existing
    /// user hooks/keys and replacing only previously cmux-owned entries. Uses a
    /// here-doc'd python3 merger for robust JSON editing; falls back to a fresh
    /// file when python3 is unavailable.
    static func claudeInstallCommand() -> [String] {
        let hooksJSON = jsonString(claudeHooksObject())
        let py = """
        import json, os, sys
        p = os.path.expanduser('~/.claude/settings.json')
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            cfg = json.load(open(p))
            if not isinstance(cfg, dict): cfg = {}
        except Exception:
            cfg = {}
        add = json.loads(os.environ['CMUX_HOOKS'])
        hooks = cfg.get('hooks')
        if not isinstance(hooks, dict): hooks = {}
        for ev, entries in add.items():
            cur = hooks.get(ev)
            if not isinstance(cur, list): cur = []
            cur = [e for e in cur if not (isinstance(e, dict) and any(
                isinstance(h, dict) and h.get('_cmux') == '\(marker)' for h in e.get('hooks', [])))]
            hooks[ev] = cur + entries
        cfg['hooks'] = hooks
        json.dump(cfg, open(p, 'w'), indent=2)
        """
        // Pass the hooks JSON via env to avoid quoting it inside the python source.
        return ["sh", "-c", "CMUX_HOOKS=\(shSingleQuote(hooksJSON)) python3 -c \(shSingleQuote(py))"]
    }

    // MARK: - Codex (~/.codex/hooks.json)

    /// The nested `hooks` object cmux merges into the remote `~/.codex/hooks.json`.
    static func codexHooksObject() -> [String: Any] {
        func entry(_ state: String) -> [String: Any] {
            ["hooks": [[
                "type": "command",
                "command": hookScript(agent: "codex", state: state),
                "timeout": 5,
                "_cmux": marker,
            ]]]
        }
        return [
            "SessionStart": [entry("running")],
            "UserPromptSubmit": [entry("working")],
            "Stop": [entry("idle")],
        ]
    }

    /// Remote shell command that merges cmux's hooks into `~/.codex/hooks.json`
    /// under the top-level `{"hooks": {...}}` shape, same replace-cmux-owned logic.
    static func codexInstallCommand() -> [String] {
        let hooksJSON = jsonString(codexHooksObject())
        let py = """
        import json, os
        home = os.environ.get('CODEX_HOME') or os.path.expanduser('~/.codex')
        p = os.path.join(home, 'hooks.json')
        os.makedirs(home, exist_ok=True)
        try:
            cfg = json.load(open(p))
            if not isinstance(cfg, dict): cfg = {}
        except Exception:
            cfg = {}
        add = json.loads(os.environ['CMUX_HOOKS'])
        hooks = cfg.get('hooks')
        if not isinstance(hooks, dict): hooks = {}
        for ev, entries in add.items():
            cur = hooks.get(ev)
            if not isinstance(cur, list): cur = []
            cur = [e for e in cur if not (isinstance(e, dict) and any(
                isinstance(h, dict) and h.get('_cmux') == '\(marker)' for h in e.get('hooks', [])))]
            hooks[ev] = cur + entries
        cfg['hooks'] = hooks
        json.dump(cfg, open(p, 'w'), indent=2)
        """
        return ["sh", "-c", "CMUX_HOOKS=\(shSingleQuote(hooksJSON)) python3 -c \(shSingleQuote(py))"]
    }

    // MARK: - helpers

    /// Deterministic JSON encode (sorted keys) for embedding in the install command.
    static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Single-quotes a value for safe `/bin/sh` embedding.
    static func shSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
