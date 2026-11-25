# iOS agent instructions

The iPhone install and authentication gates, local simulators,
cross-tag Mac access, and dev auth profiles live in `ios/AGENTS.md` at the
repository root. They apply to work under `Packages/iOS/` as well, so read that
file too.

## CmuxConversation and CmuxTabsKit live here

`Packages/iOS/CmuxConversation` and `Packages/iOS/CmuxTabsKit` live in
`feat-cmux-next`, and this copy is the only one (Aziz, 2026-11-11). Make every
change inline, in these folders, like any other app code. Do not open a pull
request into, sync to, or copy from `feat-imsg-parity-gui` or
`feat-cmux-next-tabs-kit`: those branches are frozen and nothing reads them. The
packages stay separate SwiftPM packages, so they still build and test on their own.
Before 2026-11-11 a rule kept them byte-identical to those branches, and every
change made here without a hand sync stopped cmux INTERNAL TestFlight builds
(eight times between 2026-10-30 and 2026-11-11).

## Follow the Apple Human Interface Guidelines

Before you add or change iOS UI, fetch and read the Apple Human Interface
Guidelines page for the component or pattern you are touching
(https://developer.apple.com/design/human-interface-guidelines), and follow it
by default. This covers layout, navigation, gestures, keyboard behavior,
haptics, color, typography, and system component usage. When cmux deviates
from the HIG deliberately, say so in the PR description and name the HIG page
you checked. If you cannot fetch the page (offline sandbox), state that in the
PR instead of guessing.

## macOS and iOS parity

The cmux-next parity rule is in the root `CLAUDE.md` ("macOS and iOS parity"). It applies
to the cmux-next iPhone app (`cmux-next-ios/`) and the packages it uses here, not to classic
`ios/`.
