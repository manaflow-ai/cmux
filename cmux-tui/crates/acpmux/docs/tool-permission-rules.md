# Tool and folder permission rules v1

Status: Agreed on 2026-10-02. Implementation follows the grouped permission panel and checkpoint recovery; the handoff boundary is pinned in handoff contract v1.1. acpmux owns Allow / Ask / Deny for permission requests delivered through ACP; the pane and CLI share that decision path. Coverage is `acp_requests_only`, isolation `unverified`. Session/handoff `enforcement.policy` remains the existing named policy id; rule coverage is separate.

## Rules and matching

A rule has `ruleId`, `effect: allow|ask|deny`, `selector` and `folders[]`. Selectors are either `{kind: <known ACP kind>}` (an explicit tool class, every ACP agent) or `{harness: <family>, name: <exact adapter tool name>}`. No fuzzy title, prefix, raw-input name, wildcard or command-text matching. Show kind rules as “All command tools”, “All edit tools”, etc., rather than implying exact-tool identity. Host-generated fs requests use exact `acpmux/fs.read_text_file` and `acpmux/fs.write_text_file` identities. Claude's owned translator supplies exact names in `_meta.claude.tool`; the current Codex adapter supports kind rules until it has a versioned exact-name normalizer. An unknown name cannot satisfy an exact rule; a known kind can still match an explicit kind rule. Interactive requests and unknown ACP kinds stay on the existing individual path.

`folders: []` means no folder restriction, shown as “All folders”; pathless tools can match only this form. A folder is `{root: <absolute directory>, relation: exact|descendants}` resolved on the session host. Reject symlink roots, persist canonical root and filesystem identity, and compare path components. Canonicalize existing paths or the nearest existing parent for new files, including traversal. Scope changes/replaced roots invalidate Allow. An Allow requires every reported affected path covered; a Deny matches any covered path. Missing/ambiguous paths cannot satisfy a folder Allow. A shell command never gets folder coverage from cwd or guessed command arguments. Matching failure where a restriction cannot be evaluated forces Ask, not an automatic default approval.

Paths from ACP locations remain agent-reported, with coverage `reported_paths`; host-generated fs/read_text_file and fs/write_text_file requests report `host_paths`. A request can omit effects, or change a symlink after evaluation. Canonical matching therefore does not establish execution isolation. The UI always shows this boundary, including when a scoped Allow matches.

## Decisions, state and compatibility

Precedence is hard deny-all, explicit Deny, explicit Ask, explicit Allow, chat allowance, named policy default. Explicit Ask cannot be bypassed by chat or legacy automatic approval. If metadata needed to evaluate a restriction is unavailable, ask. A scoped Allow alone is not a deny outside that scope: show the effective named default beside the rules. Automatic new-rule Allow selects an offered unique allow_once only; it never chooses an always option or invents one.

Rules are session-scoped. LocalStore persists a versioned rule record, revision and receipts with the session; initialize from the legacy object when the new record is absent. MemoryStore reports `durability: volatile` and clears all rule state on restart; LocalStore reports `persistent`. This migration and storage path belong to the daemon slice. Limit to 128 rules, 8 folders per rule and 64 KiB UTF-8 encoded input; refuse, never truncate. Canonicalization is bounded and off async worker locks; recheck the session/rules revision and permission epoch before applying a result. Full validation precedes one serialized write. A committed rule/policy change revokes chat allowance, invalidates reviewed permission revisions, while leaving existing callbacks pending. A stale responder gets `policy_changed` and rereads; it never approves under the old rules. Group responders recheck restrictions under the same permission lock. Already-sent effects cannot be revoked; disconnect never answers an ask. The existing broad chat allowance wording remains and stop/restart clears it.

Keep legacy `_acpmux/set_rules` and its object/CLI format. Store legacy and v1 rules separately and expose legacy rules read-only in the editor; do not reinterpret old patterns as scoped identities. Evaluate both, with Deny/Ask winning before either source of Allow. Legacy writes use that serialized mutator with a generated key, preserve v1 rules, and participate in the same revision/invalidation path. Their legacy API offers no client-key replay guarantee. Removing one layer never silently removes the other.

## Operations

Advertise both methods in initialize `_meta.acpmux.operations`, include `permissionRules` in its features array and advertise `_meta.acpmux.permissionRules.version: 1`; expose UI only with both operations and version 1.

| Method | Parameters | Result |
| --- | --- | --- |
| `_acpmux/permission_rules_get` | `{sessionId}` | `{sessionId, revision, rules, legacyRules, policy, coverage, durability, limits, tools, lastMutation}` |
| `_acpmux/permission_rules_set` | `{sessionId, expectedRevision, idempotencyKey, rules}` | `{record, replayed}` |

`revision` is a decimal string. `tools` reports selectors usable by the connected adapter, separately from observed display titles; it does not claim a complete registry. Coverage includes identity level and reported/host/unknown path provenance. `lastMutation` records the last committed key and revision. Persist the record plus the last 64 write receipts atomically before acknowledgement. Same key/body replays the first result before revision checking; another body is `key_conflict`. `stale_revision` returns the current record; validation/not_found use existing JSON-RPC error codes. An evicted receipt cannot execute its original body because its expectedRevision is stale; never revise that field during recovery. With LocalStore, daemon restart preserves rules/revision/receipts and clears chat grants and pending callbacks. After timeout/reconnect read first, then replay the same body/key; never replace a newer local revision with an older replay snapshot, and reread if necessary. No offline mutation queue. Emit `permission_rules` and session_changed on committed writes. Person-only native actions route pane/CLI controls to this path.

## Fork, handoff and pane

On the same daemon, fork transfers the whole rule set for the requested harness/cwd, revalidating absolute scope identities without rebasing roots to a different cwd; it never copies chat allowance or mutation keys. Handoff transfers compatible kind rules, on the same daemon/cwd with revalidated canonical roots. Drop and list unmappable exact-name or legacy Allow rules; this narrows the target. Only an unmappable Deny or Ask refuses prepare with `rules_unmappable` and `data.ruleIds`, keeping the source intact. The capsule review shows dropped rule ids before start. Check source/target rule revision and fingerprint freshness only while the handoff remains draft; `rules_changed` carries the current handoff and requires discard plus fresh prepare. A start retry with the same promptId on a starting/started record returns its first outcome before any freshness check, even after rules change. Neither refusal belongs to capsule draft edits. This boundary is agreed with the handoff owner in contract v1.1. Never silently omit Deny/Ask rules or relabel named policy as proof they transferred.

Pin `Handoff.rules` as:

```ts
rules: {
  source: {revision: string; fingerprint: string};
  target: {revision: string; fingerprint: string};
  transferred: string[]; // source ruleIds carried as compatible kind rules
  dropped: string[];     // source ruleIds dropped, Allow only
} | null
```

Revisions are the decimal strings from permission_rules_get, separate from the numeric handoff revision. Source/target values are captured at prepare after creating the target rule set. Fingerprint is `sha256:` plus lowercase hex of UTF-8 sorted-key compact JSON `{legacyRules: <stored object or null>, rules: <array sorted by ruleId>}`. Preserve the stored legacy object and array order; do not hash the rule revision or display text. Expose legacy entry ids as `legacy:<autoApprove|autoDeny|ask>:<zero-based index>` and `legacy:default` so drops/refusals identify entries without rewriting them; reserve that id prefix for legacy entries. Without permissionRules v1 the field is null and start performs no rules freshness check.

Use a compact inline rule list with native Allow / Ask / Deny buttons, optional folder scope, effective default and matched-rule feedback. Live shortcut hints and density tokens come from the shared bridges. Copyable folder paths and rule ids are addressable. Disable writes while delivery is uncertain, with read/retry retaining the original body/key. No additional sheet.

Fixture gate: exact identity/forged title, generic kind/no-name, all/mixed paths, /app versus /app2, traversal/symlink/replaced root, shell cwd, Deny/Ask over chat/legacy/default, no always option, stale responders, concurrent/replayed/conflicting writes, bounded input, uncertain reply/reconnect/restart, stale replay after a newer write, fork/handoff transfer/refusal, lost start reply followed by a rules change and same-promptId retry, canonical fingerprint fixtures, unchanged policy ids and coverage.
