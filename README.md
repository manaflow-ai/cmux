# PR 11419 current-HEAD runtime evidence

- Source HEAD: `268856eae5af782e40075e4d7b269a90143ab307`
- Tagged cloud build: `issue-11303-local-viewport-override-b8d1368be2cd`
- Remote verification host: `cmux-austin-mini-1`
- Backend mode: off
- Runtime harness exit: 0

The persistent-socket harness observed native geometry 94x37. Client A projected 20x6 while the other client and PTY stayed native; reset, 160x100 pixel projection (20x5 cells), invalid zero dimensions, disconnect cleanup, and the checked-in tag-bound CLI helper passed. Native content revisions remained [1,1,1], emitted revisions were [2,3,4], and projected observations reported unavailable emission identity [0,0,0].

The before and after captures show the desktop unchanged while the separate client receives the local projection. They are desktop-isolation evidence and do not cover authenticated iPhone rendering.

Focused fleet tests for this HEAD passed: 4 relay-policy tests, 129 CMUXMobileCore tests, 20 iOS verified-replay tests, and 1 mounted-theme normalization test.
