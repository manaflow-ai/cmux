---
name: setup
description: Connect cmux Cloud and show the user their machines and plan. Use right after the cmux Cloud plugin is installed.
---

1. Call `get_profile` to confirm the connected cmux account. If it fails with an authentication error, ask the user to finish connecting cmux Cloud.
2. Call `open_cloud` and show the result. It lists the user's machines and the plan of the connected team.
3. If `cloud_included` is false, tell the user that the connected team's plan does not include Cloud machines and share `plan_info_url`. Do not offer to buy or upgrade anything.
4. Otherwise, suggest one next step: create a machine with `create_machine`, or start an agent on an existing machine with `run_agent`.
5. Tell the user they can open cmux Cloud from the ChatGPT sidebar at any time, and change the default agent and machine size in the plugin settings.
