# Working shelf (`sidebar.workingShelf`, off by default; 2026-11-23)

- Section: Workspaces
- Mac sends: none: the Mac app reads acpmux's session summary `backgroundWaits` and the layout reducer's `sidebar_shelf_plan`
- Phone: —
- State: missing
- Notes: A chat whose turn ended and that waits on a background task, a watch, a background subagent or a working sub-session folds into a "Working (N)" row at the end of its list and comes back when the wait ends. The phone's Workspaces list draws every row in place, as it does for the Mac's Settled and Automatic folds, so it shows each waiting chat where it is. The rule is pure Rust (`cmux-layout-reducer` `shelf`) and the count rides the acpmux summary the phone already reads, so the phone can fold the same rows without new trust policy; follow-up with its list's other folds. cmux#60227.
