---
name: whats-new
description: Tell the person what changed in cmux from build to build, what is nice and what is worth trying, from the same signed release notes the What's New page shows. Use when they ask what's new, what changed, what to try or test, what landed since their last update, or when you notice the app updated since the build you last told them about.
cmux-managed: true
---

# What's new in cmux, build to build

The person should not have to read every PR to know what to try. You read
the release notes for them and say, in a few lines, what changed since the
build they last heard about and which one or two things are worth trying
now, with how to try each.

## When to bring it up

| They say or do | Do |
| --- | --- |
| "what's new", "what changed", "anything new?", "what should I try/test?" | Sections 1 to 3 |
| "since yesterday", "since my last update", "since build X" | Sections 1 to 3 for that range |
| You see the app's build differs from the one in your memory | One line offering a summary, once per build; then section 3 only if they say yes |

Never interrupt a task for this. If they say no or ignore it, drop it until
the next build.

## 1. Which build, and where its notes are

```sh
cmux version --json                          # the running app's full version (with the nightly build)
cmux settings check-for-updates --json       # current_build, the feed URL, newest_build if one is ready
```

The notes sit next to the feed: replace the feed URL's last path part with
`notes/`. For the NEXT nightly that is
`https://files-next.cmux.com/nightly-next/next/notes/`.

```sh
NOTES=https://files-next.cmux.com/nightly-next/next/notes   # from the feed, as above
curl -fsS "$NOTES/index.json"                # {"builds": [{build, shortVersion, date, head, highlights}, ...]}, newest first
curl -fsS "$NOTES/<build>.json"              # one build's notes
```

## 2. Read the range

The range is every build after the one the person last heard about (from
your memory, or the build they name) up to the running build. With nothing
remembered, use the running build and the two before it. Read at most ten
builds; say so when the range is longer.

In each build's notes, in this order:

- `whatsNew.entries`: the highlights. Each has `title.en`, `summary.en`,
  `category` (new, improved, fixed), and sometimes `tryIt` (an `action` id
  or a `cmux://` `deeplink`), `docs` and `pr`. Only builds whose index row
  has `highlights` above 0 carry curated ones; entries with an id starting
  `summary-` are generated from commit titles, so count them with the rest
  and never offer one as worth trying.
- `highlights`: the same items in the older shape (`title`, `body`,
  `category`), when `whatsNew` is missing.
- `items`: every PR that landed (`title`, `pr`, `author`). Use these only to
  answer "did X land?" or to count the rest; never read them all out.

## 3. Tell the person

At most six lines:

1. One line: which builds this covers ("Since 1.0.0-nightly.41317… (this
   morning): 3 builds").
2. Up to three highlights worth trying, newest first, entries with a `tryIt`
   ahead of the rest. One line each: what it does for them, then how to try
   it. Offer to run a `tryIt` for them: `cmux action run <action>` or, for
   a deeplink, `open 'cmux://…'` (macOS `open`; `cmux open` does not take
   `cmux://` links).
3. One line for the rest ("plus 9 fixes"), offering the full list.

Link each highlight's PR (`https://github.com/manaflow-ai/cmux/pull/<pr>`)
when it has one. To show the whole page instead: `cmux action run
updates.whatsNew`.

Then remember the newest build you covered, so next time you start there.

Say only what the notes say. If a fetch fails or a build has no notes, say
which and stop there; never guess what a build contains.
