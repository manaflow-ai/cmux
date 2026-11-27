# Your asks (History, default-off Labs feature)

- Section: Agent chats
- Mac sends: acpmux `_acpmux/asks {sessionId?, limit?, before?, beforeId?, view?: "next"}` through the pane relay; `chat.select` and `tab.open` open linked chats and pull requests.
- Phone: no ledger view yet; linked chats already open on the phone.
- State: missing
- Notes: RFD 0010; the ledger is local-only. A phone view needs a paired-device policy covering these records (SECURITY.md, #13742), as Costs does. This slice keeps the feature default-off and adds no remote trust path.
