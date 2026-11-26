# Send admission

Batch sends and tag expansion accept every requested recipient. The MCP schema, item parser,
tag resolver and expanded delivery list must agree: none imposes a message or recipient count
limit. Large sends use a bounded window of name resolutions and delivery chains; the window
controls work in flight, never whether a message is admitted. Each recipient gets its own
result, including errors. Messages to the same session retain their ordering and the existing
refusal when an earlier delivery has not settled.

An active goal does not lock the person's composer or the daemon's prompt path. A message can
steer into the current turn, explicitly queue behind it, or queue when its harness cannot steer.
Goal-continuation validation applies only to the continuation's provenance, not to ordinary
messages.

The failure pattern was treating a scheduling window as an admission policy. Raising a fixed
count merely moves the failure. Detectors in the existing acpmux suites:

- `a_batch_has_no_message_count_cap`: 1,001 messages survive parsing.
- `large_batch_and_tag_sends_reach_every_recipient`: explicit and tag sends reach 65 real
  daemon sessions, crossing every former count limit and the dispatch window.
- `an_active_goal_accepts_the_persons_steered_and_queued_sends`: a fake harness reports a
  native goal, then the real CLI sends through all three running-turn paths. Goal assertions
  read `session_detail`: the compact `session_summary` does not include the goal payload.

Buffered async work owns its session names, client handles and request metadata. Materialize
the boxed `Send` futures before buffering them; a lazy iterator borrowing the request can
fail the enclosing MCP server's `Send` bound even when individual operations are safe. The
fleet `acpmux` lib-test compilation detects this at the real MCP serving boundary.

These tests prove the daemon and CLI paths; the fake harness does not establish behavior of a
particular installed harness or app build. Subsession creation settings are a separate policy
from message admission.
