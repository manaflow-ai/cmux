---
name: browser
description: Drive web pages in your own cmux browser tab (open, snapshot, click, type, wait, screenshot, cookies from the person's browser). Use when a task needs a real page, a sign-in the person already has, or a screenshot of a site.
cmux-managed: true
---

# Browser use (tool pack `browser`)

Shipped by the `browser` tool pack (plans/cmux-next/chief-toolpacks-DESIGN.md). `chief pack check browser`
checks that `cmux browser` answers.

1. Open your own tab beside the chat: `cmux open URL` (prints its `tab_…`). Drive only that tab:
   `cmux browser <tab_…> <verb> --agent aN`. A `lease_held` answer names who drives a tab: leave it.
2. Read before acting: `snapshot` (numbered elements), then `click N`, `type N "text"`, `wait`.
3. The person's sign-ins: `cmux browser import-cookies --from chrome --domain SITE --reason "why"`
   (the fewest sites; the person allows it in cmux). To offer it later:
   `cmux import suggest --browser chrome --site SITE --reason "why"`.
4. A login, passkey or 2FA page you cannot pass: never wait on it. Escalate (skill
   chief-auth-escalation) and go on with work that needs no sign-in.
5. Never read or type a password or a code.
