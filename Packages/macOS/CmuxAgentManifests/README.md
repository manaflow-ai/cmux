# CmuxAgentManifests

## Agent detection manifests

Agent identity and terminal-state rules are JSON manifests. Bundled manifests
live in `Sources/CmuxAgentManifests/Resources/agent-detection/`. User manifests live at:

```text
~/Library/Application Support/cmux/agent-detection/<agent-id>.json
```

The filename stem must exactly match `id`. Adding a new id adds an agent without
an app-code change. A `session` object is optional; omit it for an agent that
should be detected and diagnosed but not offered as a restorable session.

```json
{
  "schemaVersion": 1,
  "id": "my-agent",
  "displayName": "My Agent",
  "process": {
    "matchers": [
      { "id": "cli", "processNames": ["my-agent"], "argvContainsAll": ["chat"] }
    ]
  },
  "states": [
    { "id": "permission", "state": "permission-prompt",
      "screenRegex": ["(?i)(allow|approve)"] },
    { "id": "idle", "state": "idle",
      "osc": [{ "sequence": "\u001b]9;my-agent;idle\u0007", "mode": "exact" }] }
  ],
  "session": {
    "sessionIdSource": "--resume",
    "resumeCommand": "{{executable}} --resume {{sessionId}}"
  }
}
```

### Evaluation

Process matchers are alternatives and are evaluated in declaration order.
Within one matcher, every non-empty predicate group must pass:

- `processNames`: one case-insensitive executable basename matches.
- `processPathContains`: every path fragment occurs.
- `processPathRegex`: one regular expression matches the executable path.
- `argvContainsAll`: every argument fragment occurs.
- `argvContainsAny`: one argument fragment occurs.
- `argvBasenamesAny`: one script/module basename occurs (Python options such as
  `-m` are parsed before selecting the entrypoint).
- `environmentEquals`: every key has the exact declared value.

State rules are ordered. The first rule with any matching `screenContains`,
`screenRegex`, or `osc` condition wins. Supported states are `idle`, `working`,
`blocked`, `permission-prompt`, and `done`. Regex objects may set
`caseInsensitive` and `dotMatchesNewlines` (both default to `true`). OSC modes
are `contains`, `prefix`, and `exact`; a sequence must start with `ESC ]` or the
C1 OSC introducer.

### Overrides and reloads

A user file for an existing id recursively overlays the bundled JSON object:
objects merge, scalar values replace, and arrays replace as a whole. Set the
top-level loader directive `"mergeStrategy": "replace"` to replace the entire
manifest. Replacement is also how an override can remove an optional bundled
`session` contract.

Within `session`, `cwd` accepts `"preserve"` or `"ignore"`; the legacy value
`"none"` is retained as an alias for `"ignore"`.

cmux watches the override directory, so a valid save is installed without an
app restart. Manual reload and pane diagnostics are available through:

```bash
cmux reload-agent-manifests
cmux debug-agent-manifest --surface surface:2
cmux debug-agent-manifest --surface surface:2 --osc $'\e]9;my-agent;idle\a'
```

The diagnostic is read-only and does not change focus. It reports the process,
manifest source, selected process/state rule, and a bounded trace. Screen rules
inspect the active viewport rather than historical scrollback; `--osc` supplies
an OSC capture when iterating on an OSC rule.

Validation rejects unknown fields, nulls, duplicate rule ids, empty matchers or
state rules, invalid or oversized regular expressions, malformed OSC
introducers, unsupported schema versions, and incomplete session contracts.
If a watched edit or manual reload fails, cmux reports the file and JSON path,
keeps the last-known-good generation active, and automatically accepts a later
repair.
