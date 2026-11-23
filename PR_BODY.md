## Summary

Adds `local/showcase-newtab-launcher`, a public SDK sample that owns the whole New Tab page through `cmux.newtab/1` once the person selects it with `tabs.newTabApp`.

The page includes a live clock and optional greeting, new chat, terminal and browser actions, recent agent chats, and clickable workspaces. Its manifest offers `focus`, `split`, and `compact` layout variants, plus settings for the greeting and recent-chat count.

Leo's request

> btw post customization sdk/api we ought to have lots of samples of stuff that people (at least the team) can add and try on eg weather, time, recent pr list in sidebar, some sort of new tab page variant, idk what else you had in mind, music/media player that looks better than the random one we had before

## Changelog

- Add the New Tab launcher extension, manifest, SDK source, package metadata, and README.
- Add the sample to the extensions index.
- Add a fake-host test covering the New Tab mount, live data, layout metadata, and an action tap.

## Verification

- `bun examples/extensions/build.ts --check`
- `bun test cmux-tui/crates/cmux-app-host/js/test/newtab-launcher.test.ts`
- `bunx tsc --noEmit -p examples/extensions/newtab-launcher/tsconfig.json`
- `python3 scripts/cmux-next/prepush-gate.py`

Leo-ask: ask-c571c46e17
Leo-Ask-Trace: ask-c571c46e17

Agent session: [agent session](https://cmux.com/deeplink/agent?id=aid-6a5d57c92bc3af8f96ff&model=claude-opus-5-5)
