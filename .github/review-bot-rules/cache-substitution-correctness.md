# Cache Substitution Correctness

Flag replacing a fresh authoritative read with a cached value in correctness-sensitive paths.

Report a failure when the diff swaps a synchronous fresh read of authoritative state (an on-disk index, a database row, a file) for a cached or opportunistic value in a persistence, history, undo, or snapshot path, without handling staleness.

The change must account for both failure modes:

- Cold cache: the cache has never loaded (for example right after launch). Returning nil or empty here can silently drop data the fresh read would have captured.
- Stale cache: the cache is older than the underlying state. Persisting a stale value can record the wrong identity (for example a previous agent session for a reused panel) that a later read or restore will trust.

Acceptable resolutions:

- A cold-cache fallback to a fresh read, plus an event-driven or freshness-checked cache so the persisted value cannot be arbitrarily stale.
- A documented graceful-degradation rationale explaining why staleness is harmless for this consumer (for example another always-fresh mechanism takes precedence, or the value is re-resolved downstream from disk).

Allowed cases:

- Caches used only for transient, non-persisted UI hints.
- Reads where staleness is explicitly tolerated and the reason is documented at the call site.

When reporting, name the authoritative source that was replaced, the persistence/undo consumer that now trusts the cache, and which of cold or stale is unhandled.

Background: substituting an opportunistic cache for a fresh load in the close-history snapshot introduced a stale-undo edge (https://github.com/manaflow-ai/cmux/pull/5669); the durable fix made the cache event-driven so it is always current.
