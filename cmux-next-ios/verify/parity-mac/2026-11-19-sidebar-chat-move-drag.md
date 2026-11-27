# Move a chat between machines from the sidebar: drag its row onto a machine (its group header or among its rows; This Mac, a Cloud machine) and the row slides there at once, says the step and about how long is left with a bar, then is the moved chat's row (a stop slides it back); every Move to… (menu, palette, CLI) shows the same row (`ChatMoveRows`, `ChatMoves`; 2026-11-19)

- Section: Chief and the Feed
- Mac sends: the Mac's own `cloudMove`, `cloudMoveToMachine`, `cloudBringBack` actions
- Phone: —
- State: not from a phone
- Notes: The move runs on the Mac: it copies the Mac's folder (`cmux link seed push`) and hands the agent over between daemon sockets on the Mac (`cmux link agent move`), which a paired phone may not start (SECURITY.md, "Remote CLI relay"); the chat's Move to… has no phone row either. The phone follows the chat where it lands, as it lists that machine's chats.
