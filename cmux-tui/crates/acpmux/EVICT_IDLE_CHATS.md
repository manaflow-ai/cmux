# acpmux: an idle chat is a row on disk (eviction)

Status: in progress (lane/acpmux-evict-idle-chats).

A chat with no live agent (hibernated), not attached or drawn by any client, nothing queued, no turn,
idle past `ACPMUX_EVICT_IDLE_SECS` (default 600; 0: off), and held by nobody but the hub's session map (`Arc::strong_count == 1`
under the map's lock) leaves the map: its `Session` (channels, locks, meta writer copy, context
snapshot) is dropped and the hub keeps only a compact row: the chat's serialized list summary.
Anything that reads it by id (open, attach, send, search) goes through `Hub::session_get`, which loads
the meta from the store and makes the session again, as the daemon start does.
