---
name: gdocs
description: Read, reformat, insert into, comment on, suggest in and verify a Google Doc with the `gdocs` command (no Docs API sign-in needed). Use whenever a task touches a Google Doc (docs.google.com/document); never type into the Docs page or paste by hand.
cmux-managed: true
---

# Google Docs (tool pack `gdocs`)

The Docs editor draws on a canvas: real key presses to a background tab are ignored and the page
text is not in the DOM. `gdocs` works around both: it reads the saved doc (`/mobilebasic`, or the
Drive export with a token), writes by a synthetic HTML paste on the editor's own input element,
and **verifies every write by reading the doc back**. Exit 0: done and verified; 1: written but
the read-back differs (the JSON says where); 2: not done (`error` code: `signed_out`, `read_only`,
`not_found`, `no_editor`, `browser`, ...).

Routes: with `GDOCS_TOKEN` (the pack's pasted Drive token, `chief pack status gdocs`) it uses the
Drive API and no browser; else the person's Google session in your own cmux browser tab. Pass
`--tab tab_…` (your tab; without it `gdocs` opens one beside the chat and prints its id on
stderr: reuse it). Never pass a tab another agent or the person drives.

```sh
gdocs read DOC [--format md|json|html]          # Markdown: headings, nested lists, tables, bold, links, comments
gdocs replace-outline DOC --md FILE|-            # whole body from Markdown (one paste = one undo step), verified
gdocs insert DOC --text MD [--at start|end | --after "TEXT" [--inline]] [--suggest]
gdocs comment DOC --on "TEXT" --text "COMMENT"   # anchored to the first match, verified
gdocs verify DOC --md FILE [--mode exact|contains]
gdocs open DOC                                   # edit view in your own tab; prints the tab
```

DOC is the doc URL or its id.

1. Read first: `gdocs read DOC > /tmp/doc.md`. Edit the Markdown, keep the person's wording
   unless asked, then `gdocs replace-outline DOC --md /tmp/doc.md`.
2. Markdown it understands: `#`..`######` headings, `-`/`1.` lists nested by indent (2 or 4
   spaces), `**bold**`, `*italic*`, `` `code` ``, `[text](https://…)`, pipe tables, `---`.
3. Someone else's doc, or the person asked for proposals: `--suggest` (Suggesting mode; the owner
   accepts or rejects). Suggestions are not verified (they show as tracked changes).
4. A failed verify (exit 1): read the doc, fix your Markdown or retry once; never loop. The
   person can undo a whole replace with Cmd+Z in the doc, or File > Version history.
5. `signed_out`: the tab's Google account cannot open the doc. Escalate the sign-in (skill
   chief-auth-escalation); do not type a password. `read_only`: say so, offer `comment`.
6. Test on a scratch doc you create (`cmux open https://docs.google.com/document/create`), never
   on the person's docs.
