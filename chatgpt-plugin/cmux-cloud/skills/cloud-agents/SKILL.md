---
name: cloud-agents
description: Run a coding task on a cmux Cloud machine with Claude Code, Codex, OpenCode or Pi, and follow it to completion.
---

1. Call `list_machines`. If the user did not name a machine, pick a running one and say which. If there is none, ask before calling `create_machine`.
2. Call `run_agent` with the machine id, the user's task as `prompt`, and `agent` only if the user named one. Keep the returned `terminal_id`.
3. Call `read_terminal` with `source: "output"` to follow progress. Summarize what the agent did; do not paste long logs.
4. Use `send_input` only when the user asks to answer the agent or type into the terminal.
5. When the task is done and the read_settings value `auto_pause_after_agent` is true, offer to pause the machine with `pause_machine`.
6. Confirm with the user before `delete_machine`. Never retry an action that failed because of the plan; report it with `plan_info_url`.
