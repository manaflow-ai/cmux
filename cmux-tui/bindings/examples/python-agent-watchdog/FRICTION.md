# SDK friction

1. Reconnect remains application-owned. The watchdog recreates the client,
   selects the session again, and reopens its event stream after transport loss.
2. Agent snapshots carry typed terminal IDs, which removes the old surface-ID
   guesswork. A convenience method that returned workspace ancestry for a
   terminal would still remove the manual terminal-to-tab-to-pane join.
3. Session deltas are sufficient as refresh triggers, but maintaining a local
   topology cache from every typed upsert is considerably more code than
   periodically requesting `session.snapshot`.
4. Terminal screen and history reads return `Document`, so the consumer must
   validate the `text` field at runtime. A typed text snapshot would make this
   common fallback compile-time safe.

The consumer imports only the public `cmux` resource package. It uses no raw
requests, generated protocol models, private modules, or forward-compatible
option maps.
