# iOS agent instructions

The iPhone install and authentication gates, iOS and verification capacity,
cross-tag Mac access, and dev auth profiles live in `ios/AGENTS.md` at the
repository root. They apply to work under `Packages/iOS/` as well, so read that
file too.

## Expose every capability to voice mode

Every new iOS feature or capability, however small, must also be reachable
through voice mode. When you add or change something a user can do in the app,
extend the orchestrator's tool surface in
`Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/Voice/VoiceOrchestratorTools.swift`
(declaration, execution against the shell store, and a permission tier in
`VoiceToolPermission.swift`: read / act / destructive, where destructive means
the on-screen approval card) plus the permission-tier test in
`CmuxMobileShellUITests/VoiceToolPermissionTests.swift`. If a capability
genuinely cannot be voiced (pure visual output, gesture-only interactions),
say so in the PR description instead of skipping silently.

## Follow the Apple Human Interface Guidelines

Before you add or change iOS UI, fetch and read the Apple Human Interface
Guidelines page for the component or pattern you are touching
(https://developer.apple.com/design/human-interface-guidelines), and follow it
by default. This covers layout, navigation, gestures, keyboard behavior,
haptics, color, typography, and system component usage. When cmux deviates
from the HIG deliberately, say so in the PR description and name the HIG page
you checked. If you cannot fetch the page (offline sandbox), state that in the
PR instead of guessing.
