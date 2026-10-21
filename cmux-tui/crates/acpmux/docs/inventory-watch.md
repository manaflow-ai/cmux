# Cached agent inventory changes

The machine owner can subscribe to cached inventory without starting a health
check, rescan, version lookup, CLI, sign-in or update. This is separate from
`_acpmux/watch`, whose session/profile notifications contain private diagnostics.

Require `harnessInventoryWatch` in `initialize`'s `_meta.acpmux.features` before
calling `_acpmux/harness/inventory/watch`. Never substitute the legacy health
control path when the feature is absent.

```json
{"jsonrpc":"2.0","id":1,"method":"_acpmux/harness/inventory/watch","params":{"enabled":true}}
```

Only a local Unix/Windows socket connection can subscribe. LocalApp, Web and
Peer origins are refused. Parameters must contain exactly one boolean `enabled`;
commands, machine selectors and session selectors are refused. This operation
is never forwarded to a peer, even when a request includes a remote session.
It grants no session, execution or account access.

Enabling returns the current full partial snapshot:

```json
{"view":"inventory","cached":true,"revision":0,"harnesses":[]}
```

Subsequent public cache changes produce `_acpmux/harness_inventory`
notifications with the same shape. Each snapshot uses the same allowlisted
projection as `_acpmux/harness/health {view:"inventory"}`: at most256safe profile
IDs, proven CLI families, validated versions, install channels, auth enums and
check timestamps. Paths, commands, account identities, diagnostics and update
plans stay private. Unknown CLI families remain unknown. Changes confined to
private fields produce no event or public revision change.

Snapshots replace the previous partial cache; an empty snapshot withdraws its
observations and never establishes an exhaustive "not installed" claim. Cached
reads retain their existing response shape without a `revision` field.

`revision` increases per changed projection within one health-service run. It
is not persistent and does not establish machine identity. A consumer must
first fence the connection to its admitted owner and daemon generation, then
retain the highest observed revision on that connection. A notification can
arrive before the enabling response; discard an older response rather than
rolling the projection back. Reconnecting or replacing the owner requires a
new owner check and subscription.

The channel retains only its newest snapshot. Slow consumers coalesce bursts;
the connection's bounded output queue applies backpressure. Disabling with
`{"enabled":false}` returns `{}`. Notifications queued before the disable reply
may precede it; later cache changes are not sent. Closing the connection ends
the existing fan-out task. There are no polling timers or background checks
created by this subscription.

This producer does not yet expose `agent_cli.watch` to apps. Its owner-fenced
native carrier, app permission/subscription lifecycle and provider event path
must be connected separately before that operation can be advertised.
