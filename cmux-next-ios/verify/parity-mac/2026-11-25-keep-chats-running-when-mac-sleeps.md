# Keep Chats Running When This Mac Sleeps (Settings › Agents › Agent Sessions, off by default; 2026-11-09): on the Mac's will-sleep notice, chats with a running turn move to the machine named in Move Chats To and keep going there; the chat says where it ran

- Section: Agent chat
- Mac sends: `_acpmux/sleep_handoff` (acpmux, local unix socket only), which runs `acpmux session sleep-handoff`
- Phone: —
- State: not from a phone
- Notes: The trigger is the Mac's own sleep, and the setting is the Mac's (still settable over `cmux settings`). acpmux refuses `_acpmux/sleep_handoff` to Web and peer connections: moving the Mac's chats and their uncommitted work to another machine is the person's call on the Mac. A phone push when the moved turn finishes needs the target machine to push for the Mac's paired phone, which it cannot yet (follow-up issue in the PR).
