# SDK friction

1. Agent state has no protocol-v10 change event. The watchdog must poll
   `list_agents()` even while it holds coarse and delta tree subscriptions.
   A typed agent-change event would remove the polling loop.
2. The synchronous SDK has no cancellation token, async client, or stream
   multiplexer. Clean shutdown requires one thread per subscription and closing
   the parent client from another thread to unblock reads.
3. Reconnect is application-owned. The consumer must recreate the command
   connection, identify again, restore client metadata, and reopen every
   subscription. A reconnect policy with a resubscribe callback would remove
   repetitive lifecycle code.
4. `AgentRecord` contains only a surface ID. Showing useful notifications
   requires joining it manually against the full workspace, screen, pane, and
   tab tree. A public surface-context lookup helper would make this common join
   reliable.
5. Reading the tail of scrollback takes two calls because the total row count
   is learned only after `read_scrollback(start, count)`. A
   `read_scrollback_tail(count)` helper would avoid the probe.
6. Coarse and delta tree events are mutually selected per subscription, so a
   consumer that audits both semantics opens two sockets and coordinates two
   stream lifecycles.

This example uses zero raw requests and zero private imports. All commands,
models, enums, events, streams, and errors come from the public `cmux` package.
