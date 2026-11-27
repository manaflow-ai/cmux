# New Tab split composer frame preparation

- Section: Creation
- Mac sends: none; AppKit parks a New Tab renderer and captures exact-size frames before a split opens
- Phone: its own New Task composer and presentation lifecycle
- State: not from a phone
- Notes: Mac-only split-pane chrome and renderer parking. This changes no composer setting, launch request, or phone behavior; the phone does not adopt an AppKit parked pane into a desktop split.
