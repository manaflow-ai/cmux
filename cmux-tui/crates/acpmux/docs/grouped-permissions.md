# Grouped permissions v1

acpmux groups nearby ACP permission requests from one session and turn into one
reviewable ask. The pane owns presentation; the daemon owns membership, policy,
chat allowances and each underlying ACP response. Coverage is `acp_requests_only`:
actions a harness never requests are outside this layer; host isolation remains
unverified.

## Collection and choices

- A fixed 100 ms window starts at the first eligible request, with at most 32
  items. Session, turnId and cancellation epoch must match. The group then seals;
  later requests create another group. Sequential requests blocked on an earlier
  approval cannot be collected before they arrive.
- Eligibility is conservative for generic ACP: `toolCall.kind` must be one of
  `read`, `search`, `edit`, `delete`, `move`, `execute`, `fetch` or `think`.
  A request is individual when it has an explicit interactive marker
  (`toolCall._meta.acpmux.interactive` or `toolCall._meta.claude.interactive`),
  names Claude's `AskUserQuestion` or `ExitPlanMode`, or carries question/plan
  input. Missing or unknown kinds stay individual. This keeps requests with no
  harness-specific marker safe by requiring a known ACP tool kind.
- Each grouped item preserves its permissionId, original request, options and
  tool input for expansion. Legacy individual notifications/responses remain.
- `allow_once` approves only the reviewed pending items, using each offered
  `allow_once` option. If any item lacks one, neither allow choice is offered.
  `deny` selects `reject_once`, or cancels if none exists. The daemon never
  synthesizes options or selects an always option for a grouped decision.
- `allow_chat` also enables an explicit chat-wide allowance for later eligible
  requests. It expires when the session stops or the daemon restarts; turn cancel
  and client disconnect alone do not clear it. It is never copied to a fork or
  handoff. Deny-all and explicit deny rules still apply; interactive/unknown
  requests still ask. Policy or rule changes revoke it. The panel must state the
  chat-wide scope.

  A group may still be formed when one or more eligible items do not offer a
  single-use `allow_once` option. In that case its `decisions` contains only
  `deny`; the daemon never widens an item to `allow_always` or synthesizes an
  option. Requests with unknown or interactive shapes are excluded entirely.

## Protocol

All methods are advertised in initialize `_meta.acpmux.operations`, with feature
`permissionGroups`. Clients gate grouped UI on these operations. RPC names follow
the existing `_acpmux/<snake_verb>` convention.

| Method | Parameters | Result |
| --- | --- | --- |
| `_acpmux/permission_groups` | `{sessionId, groupId?}` | `{groups, chatAllowance, coverage, batching}` |
| `_acpmux/permission_group_respond` | `{sessionId, groupId, revision, decisionKey, decision}` | `{group, replayed}` |
| `_acpmux/permission_chat_revoke` | `{sessionId}` | `{active:false}` |

`decision` is `allow_once`, `allow_chat` or `deny`. Group shape:

```json
{"groupId":"uuid","sessionId":"uuid","turnId":"uuid","revision":1,
 "state":"collecting|pending|resolved|cancelled",
 "items":[{"permissionId":"uuid","request":{},"state":"pending|resolved|cancelled"}],
 "decisions":["allow_once","allow_chat","deny"],"decision":null}
```

The first member is revision 1. Each additional member increments revision, and
sealing the 100 ms collection window increments it again. Legacy per-item
resolutions and terminal changes also increment revision. No buttons while
collecting. Respond validates the whole reviewed revision and all options under
one lock before releasing any item. A stale revision returns
`stale_revision` with the current group, never a partial approval. A repeated
decisionKey with the identical body replays the receipt; a different body is
`key_conflict`. Only the first answer wins across connections. After an uncertain
reply or reconnect, read groups before retrying the identical body/key. A resolved
group cannot approve a later request. Keep the last 64 terminal groups/receipts;
evicted groups return not_found, never run again. Pending groups are bounded to 64;
overflow is cancelled and recorded, never silently approved.

The existing `_acpmux/event` stream adds `permission_group` records containing
`{group}` on seal/change/resolve/cancel, and `permission_chat_allowance` records
containing `{active}`. Watchers get `session_changed`; after lag/reconnect read
groups. Individual `permission_request` and `permission_pending` add groupId and
turnId when grouped, so modern clients suppress duplicate cards while legacy
clients remain functional. A client disconnect does not answer a permission.
`SessionSummary.pendingPermissions` continues to count underlying ACP permission
items, not groups, so existing wait and status clients retain their meaning.

Errors use existing JSON-RPC codes: -32602 invalid input/key_conflict; -32000
collecting/stale_revision/already_resolved/policy_changed/budget_exceeded; -32002
not_found. `data.reason` is the stable discriminator and `data.group` is included
for state conflicts. No on-disk session schema changes; restart clears pending
callbacks and chat allowances and requires new asks.

Fixture gate: concurrent burst and late request, per-session/turn separation,
chat scope and revocation, explicit deny, unknown/interactive input, missing safe
options, legacy resolution race, competing responders, replay/key conflict,
cancel/stop/disconnect/reconnect and fixed bounds. The permission panel is a
separate change; this daemon slice does not edit or generate the pane bundle.
