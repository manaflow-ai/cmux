# cmux-next-ios design specification

Status: v1 draft, 2026-10-12. Owner: `feat-cnx-ios`. Target: iOS 26.0+ (verify on 26 and 27),
iPhone first, iPad later. Read `cmux-next-ios/PLAN.md` first; this file is the visual and interaction
contract for every `CmuxMobileKit` feature module. `CmuxMobileDesign` implements the tokens in section 2;
modules never hardcode a color, size, spring or haptic that is listed here.

How to read the numbers: all sizes are points (pt). References were captured on an iPhone 17 Pro
Max (440 x 956 pt, saved as 619 x 1344 px JPGs, so 1 px = 0.711 pt). Measurements quoted as
"measured" come from those captures; values quoted as "chosen" are our decision with a reason.
Reference files live outside the repo in `~/Downloads/cmux-native-references/{Claude,ChatGPT,Grok}/`
and are cited by file name only. Do not copy them into the repo.

---

## 1. Global language

### 1.1 What Claude, ChatGPT and Grok share (we follow all of it)

| Trait | Evidence | cmux-next-ios rule |
| --- | --- | --- |
| Dark mode is near or true black; content has no cards behind prose | `chatgpt-02-work`, `grok-01-home-keyboard` (#000000), `claude-09-chat` (#151515) | Dark background is `#000000`. Light background is `#FFFFFF`. |
| Chrome floats: glass circles and capsules, never a solid nav bar | All top bars, e.g. `chatgpt-17-diff-table-stream`, `grok-05-streaming-code` | Native iOS 26 toolbars (they are glass), `toolbarBackgroundVisibility` left default (none). |
| Top bar: leading glass circle (menu or back), centered title or segmented switch, trailing glass capsule of 1 to 2 actions | `chatgpt-01-new-chat`, `claude-09-chat`, `grok-05-streaming-code` | Same, via `ToolbarItem(.topBarLeading)`, `.principal`, `ToolbarItemGroup(.topBarTrailing)`. |
| Content scrolls under the chrome with a soft scroll edge effect | `grok-06-scroll-edge-top`, `chatgpt-23-sidebar-selected-expanded` | Default soft edge effect on every scroll view; hard only for terminal TUI mode. |
| Composer is a rounded rect card floating at the bottom: text row over a controls row (`+`, model pill, mic, primary circle) | `claude-05-composer-focused`, `grok-03-composer-typed`, `chatgpt-02-work` | Section 4.3. |
| Primary action is a white circle in dark mode (black in light) | `grok-03-composer-typed`, `claude-09-chat`, Codex CTAs in `chatgpt-11-codex-connect-empty` | The cmux-next accent is neutral (foreground), so this already matches. No blue anywhere. |
| `+` opens a native glass menu (2 of 3) | `chatgpt-04-plus-menu`, `grok-02-plus-menu` (Claude uses a sheet, `claude-06-add-context-sheet`) | Native `Menu`. |
| User message is a right-aligned rounded bubble; assistant text has no bubble | `claude-09-chat`, `grok-05-streaming-code`, `chatgpt-17-diff-table-stream` | Gray bubble (Claude and Grok); ChatGPT's tinted blue bubble is rejected (blue). |
| Code card: language label + copy, mono body, horizontal scroll, no line numbers | `grok-05-streaming-code`, `chatgpt-17-diff-table-stream` | Section 4.6. |
| Under an answer: small icon action row; `...` menu with a timestamp header | `chatgpt-24-answer-end-actions`, `chatgpt-25-answer-more-menu`, `grok-07-answer-end-actions`, `grok-08-more-menu` | Section 6.7. |
| Long-press a bubble: lift + menu with timestamp header, Copy, Select text, Share | `chatgpt-19-bubble-context-menu`, `chatgpt-20-select-text` | Native `.contextMenu` with a `Section` header. |
| Jump-to-bottom glass circle above the composer, hidden at bottom | `chatgpt-17-diff-table-stream` (centered), `grok-05-streaming-code` (trailing) | Centered (ChatGPT): it does not collide with trailing scroll indicators. |
| Empty state: centered small glyph, title, one secondary line, white capsule CTA, optional text button | `claude-02-code-empty`, `chatgpt-11-codex-connect-empty`, `chatgpt-28-projects-empty` | Section 7.2. |
| Failure: inline card in transcript, list-level "Couldn't load ..." + Retry capsule | `grok-09-failure-paywall-card`, `chatgpt-06-codex-error-state` | Section 7.3. |
| Settings: inset grouped, leading line icons, chevrons, Log out alone in red, version footer | `claude-07-settings`, `claude-08-settings-bottom`, `chatgpt-13-settings-bottom`, `grok-12-settings`, `grok-13-settings-bottom` | Section 9. |
| Sidebar: icon rows, then recents, primary capsule bottom-left, settings or avatar circle bottom-right | `chatgpt-03-sidebar`, `claude-01-sidebar`, `grok-11-sidebar` | Section 3.3, repurposed for teams. |
| Filters and sorts are native pull-down menus with checkmarks | `chatgpt-07-codex-title-menu`, `chatgpt-31-filter-menu` | Native `Menu` + `Picker(.inline)`. |
| Remote device pairing: empty state, intro, QR scan, 4+4 manual code | `chatgpt-05` to `chatgpt-11` | Section 5.6 (our Worker codes are `XXXX-XXXX`). |

### 1.2 Where they differ, and the pick

| Topic | Claude | ChatGPT | Grok | Pick and why |
| --- | --- | --- | --- | --- |
| Dark background | #151515 warm gray | #000000 | #000000 | #000000: 2 of 3, OLED, and the brief asks for true black. |
| Assistant font | Serif (Tiempos-like) | SF Pro | SF Pro | SF Pro `body`. A serif is Claude's brand, not shared language. |
| User bubble | #2C2C2A gray | #020661 blue tint | #333333 gray | Gray (`bubble` token). No blue. |
| Primary circle when empty | Voice waveform (white) | Voice waveform (blue) | "Speak" capsule (white) | We have no voice mode: a send arrow, disabled at 30% when empty (ChatGPT's own Scheduled composer, `chatgpt-30-scheduled`). There is no mic button: iOS has no API to start dictation, so the keyboard's own mic dictates into the field. |
| `+` | Sheet with photo strip | Menu | Menu | Menu (2 of 3). Photos opens `PhotosPicker` inline. |
| Sidebar | Push-aside card | Push-aside card | Full-screen page | Push-aside card (2 of 3), section 3.3. |
| Settings presentation | Sheet, swipe to dismiss | Full-screen, X only | Sheet | It is a tab in cmux-next-ios (the brief), so no presentation question. Sub-pages push. |
| Jump-to-bottom position | n/a | Centered | Trailing | Centered. |
| Toggle tint | Blue | Green | n/a | System green, the `success` token, pinned with `.toggleStyle(.cmuxMobileSwitch)` (the neutral app tint would otherwise make on switches white in dark, black in light). Not blue. |
| Settings search | none | none | Floating field at the bottom | None in v1: our settings fit on two screens. |
| Mode switch in title | none | Chat / Work segmented | Ask / Imagine / Build | We use the tab bar for top-level areas, so no title segmented control on roots. The pattern is reused inside screens (Unified / Split in the diff viewer). |

### 1.3 cmux-next theming (minimal)

- The cmux-next accent is neutral: `accent = textPrimary` (see `plans/cmux-next/spec-proposals/visuals/design-tokens.md`, "There is no accent hue by default"). In cmux-next-ios this is `Color.primary`: white in dark, black in light. Every "primary" control (CTA capsules, send circle, selected chip) uses it. That is the Default of the user's accent theme: Settings > Appearance > Accent color (`CmuxMobileAccentTheme`, `Accent.swift`) offers Default, Blue, Magenta, Cyan, Green, Yellow and Red, named as the desktop's `appearance.accent`, and every chrome tint (`accent`/`onAccent`, `Color.cmuxMobileAccent`) reads it. Never hard-code a hue in chrome (Leo, 2026-10-31: "I SAID NO BLUE AS A MATTER OF \"THIS PROBABLY NEEDS TO BE THEMED IN THE DESKTOP APP OR EXAMINED\"").
- Chrome outside the terminal is the AI-app neutral system above (true black / white), not the terminal background. The Ghostty default `#282C34` is not used for app chrome.
- The terminal screen (section 10) and code syntax colors take the terminal theme: `ThemeTokens.derive` from the active Ghostty theme supplies the terminal background, the composer and key bar tint on that screen, and the syntax palette (ANSI 1 to 6) for code and diffs.
- Team colors (user-chosen, section 3.4) are the only saturated hues in chrome. Status uses system green, red and yellow.

---

## 2. Tokens (`CmuxMobileDesign`)

### 2.1 Colors

Implement as `Color` extensions backed by dynamic `UIColor(dynamicProvider:)`. Respect
Increase Contrast by using the "High contrast" column where given.

| Token | Dark | Light | Notes |
| --- | --- | --- | --- |
| `bg` | `#000000` | `#FFFFFF` | Every root, transcript, list background. |
| `bgGrouped` | `#000000` | `#F2F2F7` | Settings and grouped lists. |
| `surface` | `#1C1C1E` | `#FFFFFF` | Grouped rows, cards. Measured ChatGPT settings rows #1B1B1D. |
| `surfaceRaised` | `#2C2C2E` | `#F2F2F7` | Cards on `surface`, skeleton base, inline inputs. |
| `sheet` | `#1C1C1E` | `#F2F2F7` | Opaque sheet background at full height (glass at partial heights is system). |
| `bubble` | `#2C2C2E` | `#EDEDED` | User message bubble, feed quote bubble. Measured Grok #333333, Claude #2C2C2A. |
| `codeBg` | `#1C1C1E` | `#F5F5F7` | Code and diff cards. Measured ChatGPT #212121; aligned to `surface` for one fewer gray. |
| `fill` | `#FFFFFF` @ 8% | `#000000` @ 5% | `+` circle, chips, mic circle, idle key caps. |
| `fillSelected` | `#FFFFFF` @ 16% | `#000000` @ 9% | Selected sidebar row (measured ChatGPT #282828 on black = 16%), selected chip. |
| `fillPressed` | `#FFFFFF` @ 22% | `#000000` @ 13% | Pressed state of custom rows and keys. |
| `separator` | `#38383A` | `#C6C6C8` | Use `Color(.separator)`; 0.5 pt (1 px) hairlines. |
| `label` | `#FFFFFF` | `#000000` | `Color.primary`. |
| `label2` | `#EBEBF5` @ 60% | `#3C3C43` @ 60% | `Color.secondary` / `.secondaryLabel`. |
| `label3` | `#EBEBF5` @ 30% | `#3C3C43` @ 30% | Placeholders, gutters, disabled. `.tertiaryLabel`. |
| `accent` | `#FFFFFF` | `#000000` | The user's accent (Default shown; hues in `Accent.swift`). Set as the app `tint` so system controls follow, except switches (`success`); containers with switches use `cmuxMobileNeutralControlTint()`. |
| `onAccent` | `#000000` | `#FFFFFF` | Text and glyphs on `accent` fills (the same for every accent). |
| `success` | `#30D158` | `#34C759` | Mac online dots, connected, toggles. |
| `danger` | `#FF453A` | `#FF3B30` | Destructive, errors, Log out. |
| `warning` | `#FFD60A` | `#FFCC00` | Permission prompts, scanner corner guides (measured yellow, `chatgpt-08-codex-qr-scan`). |
| `offline` | `#48484A` | `#C7C7CC` | Mac offline dots. |
| `diffAddText` | `#3FB950` | `#1A7F37` | GitHub Primer. Inline diffs in transcripts use text color only. |
| `diffDelText` | `#F85149` | `#CF222E` | |
| `diffAddRow` | `#2EA043` @ 15% | `#DAFBE1` | Full diff viewer only. |
| `diffDelRow` | `#F85149` @ 15% | `#FFEBE9` | |
| `diffAddWord` | `#2EA043` @ 40% | `#ACEEBB` | Word-level highlight. |
| `diffDelWord` | `#F85149` @ 40% | `#FFCECB` | |
| `diffHunkBg` | `#FFFFFF` @ 4% | `#DDF4FF` @ 50% | Hunk header rows. |
| `scrim` | `#000000` @ 40% | `#000000` @ 20% | Sidebar-open overlay on the pushed card (section 3.3). |

Team palette (section 3.4), dark / light pairs from Apple system colors: red `#FF453A/#FF3B30`,
orange `#FF9F0A/#FF9500`, yellow `#FFD60A/#FFCC00`, green `#30D158/#34C759`, mint
`#63E6E2/#00C7BE`, teal `#40CBE0/#30B0C7`, cyan `#64D2FF/#32ADE6`, blue `#0A84FF/#007AFF`,
indigo `#5E5CE6/#5856D6`, purple `#BF5AF2/#AF52DE`, pink `#FF375F/#FF2D55`, brown
`#AC8E68/#A2845E`, gray `#8E8E93/#8E8E93`. Stored on the server as `#RRGGBB` (the dark value);
the client maps it to the pair. Blue is allowed here because it is user content, not chrome.

Syntax palette (code, diffs): derived from the active terminal theme via `ThemeTokens`:
keyword = ANSI 5, string = ANSI 2, number/constant = ANSI 3, type = ANSI 6, function = ANSI 4,
comment = `textTertiary`, punctuation = `textSecondary`, plain = `textPrimary`; each pushed to
3:1 on `codeBg` (the same `readable` rule as macOS). Fallback theme: Apple System Colors.

### 2.2 Typography

SF Pro through Dynamic Type text styles only (`Font.TextStyle`); never fixed sizes except mono in
terminal and diff gutters. Sizes below are the Large (default) content size.

| Role | Style | Size / weight | Used for |
| --- | --- | --- | --- |
| `screenTitle` | `.headline` | 17 semibold | Centered toolbar titles (all roots and pushed screens). |
| `sidebarTitle` | `.title2.weight(.semibold)` | 22 semibold | Sidebar header "cmux" (measured ChatGPT header ~22). |
| `heroTitle` | `.title.weight(.bold)` | 28 bold | Welcome headline. |
| `sheetTitle` | `.title3.weight(.semibold)` | 20 semibold | Leading sheet titles ("Pair manually", `chatgpt-09-codex-pair-manual`). |
| `emptyTitle` | `.headline` | 17 semibold | Empty and error titles. |
| `body` | `.body` | 17 regular, line spacing +6 (measured ChatGPT line pitch 28) | Assistant prose, rows, user bubbles. |
| `rowTitle` | `.body` | 17 regular | Settings, sidebar, list rows. |
| `rowSubtitle` | `.subheadline` | 15 regular, `label2` | Second line of rows, empty-state body. |
| `meta` | `.footnote` | 13 regular, `label2` | Timestamps, durations ("5.47s", `grok-07`), section footers. |
| `chip` | `.subheadline.weight(.medium)` | 15 medium | Chips, model pill name; effort suffix in `label2` (`claude-09-chat`: "Sonnet 5.5 Medium"). |
| `cta` | `.headline` | 17 semibold | CTA capsule labels. |
| `toolRow` | `.subheadline` | 15 regular, `label2`; file names in `.monospaced()` | Tool call rows. |
| `codeBody` | `.system(size: 13, design: .monospaced)` scaled with `@ScaledMetric(relativeTo: .footnote)` | 13 regular, line height 19 | Code and inline diffs (measured Grok ~13). |
| `codeLabel` | `.footnote.weight(.medium)` | 13 medium | Code card header ("Python", "Diff"). |
| `diffGutter` | `.system(size: 11, design: .monospaced)` | 11, `label3` | Diff line numbers. |
| `terminal` | Ghostty font from config, default SF Mono 13 | | Terminal only. |

Markdown in assistant text: H1 `.title3.bold`, H2 `.headline`, H3 `.subheadline.bold`;
paragraphs 12 pt apart; lists with 8 pt item spacing, 20 pt indent; inline code mono 15 on
`fill` with 4 pt radius and 3 pt horizontal padding; links underlined `label` (no blue);
tables per section 6.6; blockquote 3 pt leading bar `separator`.

### 2.3 Spacing, sizes, radii

4 pt grid. Core metrics (measured unless noted):

| Metric | Value | Source |
| --- | --- | --- |
| Screen side margin | 20 | Top circles start at x = 20 in all three. Transcript text margin 20 (ChatGPT 22, Grok 22). |
| Glass circle button | 44 x 44, symbol 17 pt regular | `chatgpt-01`: circle 20..64. |
| Glass capsule group | height 44, 2 items, item pitch 44 | `claude-09-chat` (new chat + more). |
| Toolbar vertical center | safe-area top + 22 | System toolbar; do not hand-place. |
| Composer card | radius 24 continuous, min height 96, side margin 12 (ChatGPT/Grok 18..22, chosen 12 to widen text) | `claude-09-chat` 823..918, `grok-03`. |
| Composer collapsed capsule | height 48, radius 24, side margin 20 | `chatgpt-17` "Work with ChatGPT". |
| Composer gap above keyboard | 8 (card bottom to the keyboard's top edge) | Measured in pixels (round 2, `verify/round2.md`): `claude-05` 7, `grok-01` and `grok-03` 7, `chatgpt-01` 13; Messages 16. The AI apps cluster at 7; 8 is within the 0.7 pt measurement step. cmux-next-ios measures 8.0 (`gap-tab`). |
| Composer gap above home indicator (no tab bar) | 8 above the bottom safe area | `claude-09-chat`. |
| Small circle in composer (`+`, mic, primary) | 36 x 36, symbol 15 pt semibold for primary, 17 regular for others | All three. |
| Model pill | height 34, horizontal padding 12, capsule, `fill` | `claude-05-composer-focused`. |
| CTA capsule large | height 52, full width minus 2 x 20, radius 26 | `chatgpt-10-codex-setup-onboarding`. |
| CTA capsule inline | height 40, horizontal padding 20, radius 20 | `chatgpt-06` "Retry", `chatgpt-28` "New project". |
| Sidebar primary capsule | height 48, padding 18, radius 24 | `claude-01-sidebar` "New session". |
| Settings row | 54 tall, icon 22 frame at 16 inset, label at 52 | `chatgpt-13-settings-bottom` pitch 54. |
| Inset group | side margin 20, radius 26 continuous (iOS 26 default) | All settings captures. |
| Sidebar row | 48 pitch, icon 22 frame, 14 gap, text `body` | `chatgpt-03-sidebar`. |
| List row (workspaces, files) | min 60 for two lines, 48 for one | Chosen. |
| User bubble | radius 20 continuous, padding 16 h / 11 v, max width 80% of column, trailing margin 16 | `grok-05` (bubble 50..430 on 440). |
| Code card | radius 20 continuous, header 40, body padding 16 h / 4 top / 16 bottom | `chatgpt-17` card 22..430. |
| Menu | system | |
| Corner radius rule | Nested shapes use `ConcentricRectangle` / `.rect(corner: .containerConcentric)` | WWDC25 323. |

### 2.4 Materials (Liquid Glass)

Rules from Apple (WWDC25 "Meet Liquid Glass", "Build a SwiftUI app with the new design"):
glass is for the navigation layer only, never content; never glass on glass; apply it to the
control, not its children.

| Element | API | Notes |
| --- | --- | --- |
| Toolbar items, tab bar, menus, partial-height sheets, search field | System (automatic) | Do not set bar backgrounds or `UIBarAppearance`. |
| Glass circle buttons outside toolbars (jump-to-bottom, joystick, keyboard toggle) | `.glassEffect(.regular.interactive(), in: .circle)` | 36 or 44 pt. |
| Composer card | `.glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))` | Not interactive (it holds a text view). Its inner `+`, mic and pill use `fill`, not glass. |
| Groups of floating controls that can morph (composer + jump-to-bottom; terminal key bar + joystick) | `GlassEffectContainer(spacing: 12)` + `.glassEffectID(_:in:)` | Lets the jump circle "drip" out of the composer. |
| Primary CTA | Solid `accent` fill, not glass | References show opaque white capsules. |
| Secondary CTA | `.buttonStyle(.glass)` capsule | "Pair manually instead" (`chatgpt-08`) is an outline; glass reads as the iOS 26 equivalent. |
| Banner / toast | `.glassEffect(.regular, in: .capsule)` | Section 7.4. |
| Accessibility | With Reduce Transparency, glass becomes opaque automatically; custom fills (`fill`, `bubble`) stay. Verify Increase Contrast: add a 1 pt `separator` stroke to the composer. | |

Scroll edge effect: leave the default (soft) on every `ScrollView` and `List`. Use
`.scrollEdgeEffectStyle(.hard, for: .top)` only on the terminal in TUI (alt-screen) mode and on
the diff viewer's sticky file header.

### 2.5 SF Symbols inventory

| Use | Symbol |
| --- | --- |
| Sidebar (hamburger) | `line.3.horizontal` (ChatGPT and Grok draw a custom two-line glyph; we use the SF Symbol rather than a custom asset) |
| Back | system back button (chevron) |
| New (chat, session, workspace) | `square.and.pencil` |
| More | `ellipsis` |
| Search | `magnifyingglass` |
| Tabs | Home `house` / `house.fill`; Workspaces `square.stack.3d.up` / `.fill`; Feed `bubble.left.and.text.bubble.right` / `.fill`; Settings `gearshape` / `.fill`; Search (role) `magnifyingglass` |
| Composer | `plus`, `mic`, `arrow.up` (send), `stop.fill` (stop), `keyboard`, `keyboard.chevron.compact.down` |
| `+` menu | `camera`, `photo.on.rectangle`, `paperclip` (Files), `checklist` (Plan mode), `lock.shield` (Permission mode), `slash.circle` (Commands) |
| Answer actions | `doc.on.doc` (copy, swaps to `checkmark` for 1.5 s), `square.and.arrow.up`, `arrow.clockwise`, `ellipsis` |
| Tool calls | read `doc.text`, edit `pencil`, write `doc.badge.plus`, bash `terminal`, search `magnifyingglass`, web `globe`, task/agent `person.2`, todo `checklist`, MCP `puzzlepiece.extension`, failed `exclamationmark.triangle.fill` |
| Permission | `hand.raised.fill` |
| Question | `questionmark.bubble` |
| Plan | `list.bullet.clipboard` |
| Jump to bottom | `arrow.down` |
| Mac | `desktopcomputer`, `laptopcomputer` |
| Pairing | `qrcode.viewfinder`, `number` |
| Offline | `wifi.slash`; reconnecting uses `ProgressView` |
| Load error | `cloud` (ChatGPT `chatgpt-06`); Mac unreachable `desktopcomputer.trianglebadge.exclamationmark` |
| Teams | `person.2`, invite `person.badge.plus` |
| Files | folder `folder.fill`, text `doc.text`, code `chevron.left.forwardslash.chevron.right`, image `photo`, video `film`, pdf `doc.richtext`, archive `doc.zipper`, markdown `text.document` |
| Diff | changed `plus.forwardslash.minus`, viewed `checkmark.circle` / `.fill`, expand `arrow.up.and.down`, next/prev file `chevron.down` / `chevron.up` |
| Settings icons | Account `person.crop.circle`, Teams `person.2`, Connection `point.3.connected.trianglepath.dotted`, Transport `antenna.radiowaves.left.and.right`, Paired Macs `desktopcomputer`, Terminal `apple.terminal`, Appearance `circle.lefthalf.filled`, Haptics `iphone.radiowaves.left.and.right`, Notifications `bell`, Security `faceid`, About `info.circle`, Help `questionmark.circle`, Report `flag`, Log out `rectangle.portrait.and.arrow.right` |

Symbol weight `.regular`, rendering `.monochrome` in `label` (rows: `label`, not tinted; matches
all three apps). Settings row icons 17 pt in a 22 pt frame.

### 2.6 Haptics (`CmuxMobileHaptics`)

SwiftUI `.sensoryFeedback`, or `UIFeedbackGenerator` from UIKit code. All gated by Settings >
Haptic feedback (Claude has this toggle, `claude-08-settings-bottom`; ChatGPT FAQ documents its own).
Also respect the system haptics switch (automatic) and skip all haptics in Low Power Mode (ChatGPT does).

| Event | Feedback |
| --- | --- |
| Send message / submit answer / approve | `.impact(weight: .light)` |
| Assistant stream starts | one `.selection`. Never per token (t3code ships ~3 Hz ticks and users ask to turn it off, issue #13116). |
| Turn finished while screen visible | none (the stop to send morph is enough) |
| Permission request or question arrives while its screen is visible | `.warning` |
| Task finished from Feed / Live Activity tap | none |
| Error (send failed, pair failed, code invalid) | `.error` |
| Pair success, sign-in success | `.success` |
| Team switch, chip/segment change, picker change | `.selection` |
| Sidebar crosses the open threshold during a pan | `.impact(weight: .light, intensity: 0.5)` once per crossing |
| Copy | `.impact(weight: .light, intensity: 0.7)` + icon swap |
| Joystick step | `.selection`, throttled to 30 Hz |
| Key bar key | `.impact(weight: .light, intensity: 0.5)` (setting "Key clicks", default on) |
| Pull to refresh trigger | system |
| Long press menus, toggles | system |

### 2.7 Motion tokens (`CmuxMobileMotion`)

SwiftUI `Spring(duration:bounce:)`; equivalent `response = duration`,
`dampingFraction = 1 - bounce` (bounce >= 0). UIKit:
`UISpringTimingParameters(dampingRatio: 1 - bounce, initialVelocity:)` driven by a
`UIViewPropertyAnimator(duration: duration, timingParameters:)`.

| Token | Spring | Use |
| --- | --- | --- |
| `snap` | duration 0.25, bounce 0 | Small state flips: icon swaps, chip select, jump-to-bottom fade. |
| `smooth` | duration 0.35, bounce 0 | Expand/collapse: composer, tool rows, Show more. (= `.smooth(duration: 0.35)`) |
| `snappy` | duration 0.35, bounce 0.12 | Things that arrive: new bubble, permission card, toast. (≈ `.snappy(duration: 0.35)`) |
| `drawer` | duration 0.42, bounce 0, carries pan velocity | Sidebar open/close. |
| `gentle` | duration 0.5, bounce 0 | Screen-level crossfades (team switch, launch handoff). |
| `springBack` | duration 0.3, bounce 0.3 | Joystick thumb returning to center, rubber bands. |
| `shake` | keyframes x: 0, -8, 8, -6, 6, -3, 0 over 0.4 s | Invalid code. |
| `shimmer` | linear 1.6 s, repeat forever | "Working" text, skeletons. |
| Keyboard | never animate separately | Ride the keyboard safe-area transaction (UIKit curve 7, ~0.25 s). Use `keyboardLayoutGuide` in UIKit hosts. |

Reduce Motion: replace translation/scale with opacity crossfades of `snap` length; stop shimmer
(static `label3` text); no streaming fades.

---

## 3. App structure

### 3.1 Hierarchy

```
CmuxMobileRoot
├─ Launch (storyboard) → LaunchHandoff (SwiftUI, 0.5 s)
├─ Onboarding (signed out): Welcome → Sign in (Apple / Google / GitHub / Email code) → Setup steps
└─ Shell (signed in)
   ├─ SidebarContainer (UIKit container, push-aside drawer; team switching only)
   │  ├─ TeamSidebar
   │  └─ TabView (iOS 26 native)
   │     ├─ Tab "Home"        NavigationStack → Chief conversation (root)
   │     ├─ Tab "Workspaces"  NavigationStack → Macs + workspaces → Workspace (last tab) → Terminal / Browser / Agent chat
   │     ├─ Tab "Feed"        NavigationStack → timeline → (tap) event's tab
   │     ├─ Tab "Settings"    NavigationStack → inset grouped settings → sub-pages
   │     └─ Tab(role: .search) "Search" → global search (workspaces, tabs, events, files)
   └─ Global overlays: connection banner, toasts
```

Pushed full-screen surfaces (a workspace and its tabs, Agent chat, Terminal, Browser, File preview,
Diff viewer, a Home conversation) hide the tab bar. Composer screens never show a tab bar under
the composer (Messages and every AI app agree: a conversation owns the bottom edge). One source of
truth decides it: `ShellModel.showsTabBar(on:)` (anything pushed on Home, Workspaces or the Feed
hides it; Settings pages keep it), applied per tab by `TabBarVisibility`. Pushed screens never set
it themselves: SwiftUI drops a pushed screen's hide when one update selects a tab and pushes on it
(a link, a notification tap, the launch restore).

### 3.2 TabView

```swift
TabView(selection: $tab) {
    Tab("Home", systemImage: "house", value: .home) { HomeStack() }
    Tab("Workspaces", systemImage: "square.stack.3d.up", value: .workspaces) { WorkspacesStack() }
        .badge(workspacesNeedingInput)        // count of agents waiting on you
    Tab("Feed", systemImage: "bubble.left.and.text.bubble.right", value: .feed) { FeedStack() }
        .badge(unreadQuestions)
    Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsStack() }
    Tab(value: .search, role: .search) { SearchStack() }
}
.tabBarMinimizeBehavior(.never)
.tint(.primary)                               // neutral accent: selected tab is label, not blue
```

- Minimize on scroll: off. The bar stays fully visible on every tab and every list while
  content scrolls (user decision, 2026-10-27); it never collapses to the selected tab's pill.
  Full-screen detail screens (workspace, terminal, agent chat, diff, Chief) still hide it while
  they are open.
- Search role tab: sits apart at the trailing end. It is the single global search; screens do not
  add their own `.searchable` except the Feed filter chips and file browser filename filter.
  Justification: iOS 26 native placement, and each reference app has one search entry
  (ChatGPT sidebar search, Grok bottom search, Claude sidebar search).
- Badges: count of items that need the user (questions, permission prompts). Never unread
  counts of passive events.
- No `tabViewBottomAccessory` in v1: Apple uses it for app-wide content (Now Playing); the Chief
  composer is Home-only. Revisit for a "running agents" mini status.
- Home root: the Chief composer is placed with `.safeAreaInset(edge: .bottom)` inside Home's
  content, 8 pt above the tab bar. When the composer is focused the keyboard covers the tab bar;
  the tab bar stays in place while the transcript scrolls. When a Chief turn opens a workspace tab, it pushes with the tab
  bar hidden.

### 3.3 Team sidebar (push-aside drawer)

Scope: team switching only (Stack Auth teams) plus "Invite to team". No navigation destinations,
no recents (that is the tab bar's job).

Geometry (measured ChatGPT 330, Claude 320 on a 440 pt screen):

- `sidebarWidth = min(360, max(300, round(screenWidth * 0.75)))`.
- Open: the whole `TabView` (including the tab bar) translates right by `sidebarWidth` and
  becomes a card: corner radius `displayCornerRadius` (use 44 pt; continuous), 0.5 pt stroke
  `#FFFFFF` @ 10% (dark) / `#000000` @ 8% (light), shadow `#000000` @ 30%, radius 20, x -4.
  An overlay `scrim` fades from 0 to 1 on the card; the card does not scale (neither reference
  scales). Tapping the card closes. VoiceOver: the card becomes one "Close teams" button.
- Sidebar itself is not glass: plain `bg` (both references), revealed from underneath
  (parallax: sidebar content starts at x = -40 and moves to 0 as progress goes 0 to 1).

Gestures:

- Open with the leading toolbar `line.3.horizontal` circle on every tab root (Home, Workspaces,
  Feed, Settings; not on Search and not on pushed screens, which show Back).
- Interactive pan, only on tab roots: a `UIPanGestureRecognizer` on the container begins when
  `velocity.x > 0` and `|velocity.x| > 1.5 * |velocity.y|`, the touch is not inside a horizontally
  scrollable view (code cards, tables, chip rows, terminal), and the current stack depth is 1.
  The card tracks the finger 1:1 (rubber band beyond `sidebarWidth`: offset = width + d / 3).
  On release: open if `velocity.x > 300` or progress > 0.4; close if `velocity.x < -300` or
  progress < 0.4. Animate with `drawer`, passing the pan velocity as initial velocity.
  ChatGPT opens on fast pans anywhere; this matches and also lets slow drags track.
- Close: pan left anywhere (on sidebar or card), tap card, or select a team.
- Pushed screens keep the system interactive edge-swipe back; the drawer pan must fail there
  (`require(toFail:)` the navigation controller's `interactivePopGestureRecognizer`).
- Implementation: `SidebarContainerViewController` (UIKit) hosting two `UIHostingController`s;
  SwiftUI talks to it through an `@Observable SidebarModel { progress, isOpen }`. A pure SwiftUI
  `offset` + `DragGesture` fights `ScrollView` and the tab bar; do not use it.

Swipe rules (app-wide, user decision 2026-10-13, `verify/swipes.md`):

- No list has leading-edge (swipe right) actions: a rightward pan on a tab root opens the team
  drawer. Actions that would have been leading go to the trailing edge (swipe left), the
  long-press context menu, or both. At most three trailing actions; the rest live in the
  context menu.
- Custom swipe rows (the Feed's `FeedSwipeRow`) begin their pan only for a leftward drag, or
  for a rightward drag that closes already open actions, so a rightward pan falls through to
  the drawer.
- Order is outermost first; the outermost action runs on a full swipe. A full swipe must never
  grant anything (permissions are allowed with a tap).
- Destructive actions (Delete, Deny, Decline) use the system destructive red: `role:
  .destructive` with no custom tint in a `List` (clear the shell's label tint with
  `.tint(nil)`, or the role draws white in dark mode), `UIColor.systemRed` in custom rows.
- Non-destructive actions use UIKit semantic system colors that adapt to dark mode, as Mail
  and Messages do: `systemBlue` (read state, answer), `systemIndigo` (alerts), `systemPurple`
  (Done, as Mail's Archive), `systemGreen` (Allow), `systemOrange` (Restore), `systemGray`
  (Copy path). White icon over a short label.

Content (top to bottom):

1. Header row, 20 pt side margin, centered at the toolbar line: "cmux" wordmark text
   (`sidebarTitle`) leading; trailing 44 pt glass circle `plus` → menu: "Create team",
   "Join with invite link". (Header layout is `chatgpt-03-sidebar`.)
2. Section label "Teams" (`meta`, `label2`), 20 pt margin, 24 pt above the first row.
3. Team rows (`List` style plain, no separators), each 60 pt:
   - Leading avatar 36 x 36, rounded square radius 10 continuous: team color fill with the
     emoji (22 pt) centered, or the team initial (`headline`, `onAccent`-style white) if no emoji.
     With an emoji and no color: `fill` background.
   - Title: team name, `body` semibold if selected else regular, one line.
   - Second line: Mac presence dots: up to 5 dots, each 7 x 7 circle, 4 pt spacing, `success`
     for online and `offline` for offline, online first (stable sort by name within each group),
     then "+N" in `meta` `label2` when more than 5 Macs; then " · 3 of 7 online" is NOT shown
     (the dots are the summary). No Macs: "No Macs" in `meta` `label2`.
   - Selected row: `fillSelected` background, radius 14 continuous, inset 10 pt from the
     sidebar edges (measured `chatgpt-23-sidebar-selected-expanded`).
   - Live updates: presence frames from `TeamHub` animate dot color with `snap`.
   - Context menu (long press): "Change color and emoji" (`paintpalette`), "Invite to team"
     (`person.badge.plus`), "Copy team name", divider, "Leave team" (destructive, confirmation
     alert). Pattern: `grok-15-row-context-menu`.
4. Row "Invite to team" (`person.badge.plus`, `body`), 48 pt, after the team list. Opens the
   share sheet with the Stack invitation URL from `POST /v1/teams/:teamId/invites` (show a
   `ProgressView` in the row while fetching).
5. Bottom bar (pinned, 20 pt margins, 8 pt above the bottom safe area):
   - Leading: primary capsule "Invite" with `person.badge.plus` (48 h, `accent` fill,
     `onAccent` text, `cta` font). Measured `claude-01-sidebar` "New session".
   - Trailing: 48 pt circle avatar of the signed-in user (initials on `surfaceRaised`, like
     Claude's "AA"), opens Settings > Account and closes the drawer.

Team switch: tap row → `.selection` haptic, row highlight moves (`snap`), drawer closes
(`drawer`), then the shell crossfades (`gentle`) to the new team's data; lists show skeletons
until the first `hello` frame. Persist the last team per device.

### 3.4 Team color and icon editor

Sheet (`.presentationDetents([.height(640), .large])`), glass X leading, title "Team appearance"
centered. Large avatar preview 72 pt (radius 20). Below: "Icon" group with a segmented control
Automatic / Custom / None (Automatic = the team's first letter, the default; None = color only).
Custom adds a "Character" row with an inline `TextField` on the system keyboard that keeps exactly
one grapheme (a letter, digit, symbol, or an emoji from the keyboard's emoji key); a new
keystroke replaces the old character, whitespace is ignored, and an empty field previews as
Automatic. The icon group sits above the color grid so the preview stays visible over the
keyboard. Then "Color": 13-color swatch grid (6 columns, 44 pt circles, selected ring 3 pt
`label` with 3 pt gap). "Done" docked bottom as a large CTA. Wire: `emoji` null = Automatic,
`""` = None, otherwise the character (PROTOCOL.md). Writes `PUT /v1/teams/:teamId/prefs`;
optimistic, reverts with a toast on failure. Pattern: ChatGPT new project emoji field,
`chatgpt-29-new-project-sheet`.

---

## 4. Shared components (inventory)

Every item is a SwiftUI view in `CmuxMobileDesign` (or the named module), with a preview and a
snapshot test in light and dark at Large and AX3 Dynamic Type.

### 4.1 Buttons

| Component | Spec |
| --- | --- |
| `GlassCircleButton(symbol:)` | 44 pt, toolbar item where possible; elsewhere `.glassEffect(.regular.interactive(), in: .circle)`. Symbol 17 regular. |
| `PrimaryCapsule(title:, size: .large/.inline)` | `accent` fill, `onAccent` label, `cta` font; large 52 h full width, inline 40 h. Pressed: opacity 0.85, scale 0.98 (`snap`). Disabled: `fill` background, `label3` text (measured "Continue" gray in `chatgpt-05`, "Pair" in `chatgpt-09`). Loading: label replaced by `ProgressView().tint(onAccent)`, width kept. |
| `SecondaryCapsule` | `.buttonStyle(.glass)`, same sizes, `label` text. |
| `TextCTA` | Plain `label` text button, `cta` font (e.g. "Enter code manually", `chatgpt-11`). |
| `DestructiveRow` | `danger` text and icon in its own inset group ("Log out"). |
| `IconAction` | 32 x 32 hit target around a 17 pt `label2` symbol (answer action rows). |
| `Chip(title:, selected:)` | height 36, padding 14, capsule; idle: no fill, `label` text; selected: `fillSelected` (measured ChatGPT Library chips `chatgpt-26-library-grid`). Horizontal scroll row with 8 pt spacing, 20 pt leading inset; chips do not page on swipe. |

### 4.2 Rows and lists

- `SettingsRow(icon:, title:, value:, accessory:)`: 54 pt, value `label2` trailing, chevron
  `chevron.right` 13 semibold `label3`. Toggle uses system `Toggle` (green).
- `ListRow` for workspaces and files (section 8, 11).
- `SidebarTeamRow` (section 3.3).
- `StatusDot(state:)`: 8 pt circle; online `success`, offline `offline`, busy `warning`
  pulsing opacity 0.4 to 1 (`shimmer` timing), error `danger`.
- `Avatar(kind:)`: team (rounded square), user (circle, initials), agent (circle with the
  agent's glyph on `surfaceRaised`: Claude Code, Codex, Cursor, Gemini use monochrome SF
  Symbols or template assets; never brand colors in chrome).

### 4.2.1 Lists: one text column (rule, every list)

Every list has one text column, and everything that reads as text starts on it. User
direction, 2026-10-23: "headers like Needs You and Pinned should be left aligned with all
text, this should be a principle in general."

- **Text column.** Each row's primary text (the title, and the subtitle under it) starts at
  the list's text column. Section headers, footers, inline labels ("Loading…", "No Macs
  yet", a Mac's offline line), group and disclosure titles, and icon-less rows on the same
  page start there too. Every title in a list starts at one x.
- **Grouped lists keep native headers.** In `.insetGrouped` lists (Settings and its
  pages, Devices) section headers and footers stay at the system position, the cell's
  content margin where the row icons start, as in iOS Settings. They take no
  `.cmuxMobileTextColumn()`. User direction, 2026-10-30: "the settings group headers like
  Connection and Appearance are way too indented in cmux next ios, fix."
- **Gutter.** Marks hang in a leading gutter before the text column: status and unread dots,
  disclosure chevrons, icons, small avatars, spinners, selection marks (Apple Mail's unread
  dots, iOS Settings' row icons). A group or disclosure row puts its chevron in the gutter
  and its title on the text column; extra marks (a group's color dot) follow the title.
- **Separators** start at the text column, never under the gutter.
- **Metrics** (`CmuxMobileListColumn`, `CmuxMobileDesign/ListColumn.swift`), measured from
  the row content's leading edge and scaled like `.body` with Dynamic Type:
  - plain lists (Workspaces): `plain`, a 32 pt gutter from the screen edge, text at 32 pt;
  - grouped lists (Settings and its pages, Devices): `grouped`, a 22 pt icon column (up to
    44 pt) and 14 pt to the text, so text at 36 pt from the cell's content margin, where the
    system header and footer text start;
  - a list with its own glyph size declares its column (`CmuxMobileListColumn(mark:gap:)`,
    e.g. Continue in… 32 + 12, Checkpoints 24 + 12); the Team drawer uses
    `SidebarTeamRow.textLeading` (side margin + 36 pt avatar + 12 pt).
- **How to build it.** A row puts its mark in `CmuxMobileGutterRow`; a plain list's header or
  footer, and an icon-less row in a list with marks, takes `.cmuxMobileTextColumn(kind)`. A page whose rows
  have no marks keeps the system alignment (its text, headers and footers already share
  the cell margin) and adds no icons to only some rows.
- **Exceptions.** A row's own icon or emoji that is part of its name (a workspace's icon)
  sits on the text column with the name. Centered hero cards (the account card, Chief's
  header, the Continue in… review header), empty states and centered status notes (Home's
  "Connecting to …") are not rows. Menus are the system's and already follow the rule.
- **Check.** Measure the x of each header and each row title per screen (accessibility
  frames or a pixel scan): they match within 1 pt at the default and a large text size.

### 4.3 Composer (`CmuxMobileComposer`)

States: `collapsed`, `expanded` (idle), `focused`, `running` (agent working), `queued`
(text typed while running), `disabled` (offline / no permission).

Layout (expanded or focused), inside a `GlassEffectContainer`:

```
╭──────────────────────────────────────────────╮  radius 24, glass, side margin 12
│  Ask Chief…                                   │  TextField(axis: .vertical), 1…8 lines, body 17,
│                                               │  insets 16 h, 14 top
│  (+)  [ Opus 5.5 Medium ]          (mic) (↑)  │  44 pt controls row, 8 pt from card edges
╰──────────────────────────────────────────────╯
```

- Placeholder (`label3`): Home "Ask Chief", agent chat "Reply to <agent>" (Claude: "Reply to
  Claude"), terminal "Send to <program>" (section 10), Feed inline "Answer".
- `+` (36 pt circle, `fill`): native `Menu`, sections: [Camera, Photos, Files] then
  [Plan mode (toggle, `checklist`), Permission mode > (Manual, Accept edits, Plan, Auto; `Picker`
  inline with checkmark), Commands > (slash commands from the agent's ACP `availableCommands`)].
  Grok's menu shape (`grok-02-plus-menu`): icon in a 30 pt circle, 52 pt rows. Use the native
  menu as is; do not restyle.
- Attachments: a horizontal strip above the text row: 56 x 56 thumbnails radius 12 with a
  20 pt X badge; files as 56 h chips with icon + name. Card grows with `smooth`.
- Model pill (agent chat only): "<Model> <Effort>" with effort in `label2`
  (`claude-05-composer-focused`). Tap → native `Menu`: section "Model" (Picker), section
  "Effort" (Low / Medium / High / Max, Picker). Values come from ACP session config; hide the
  pill when the agent exposes none. (ChatGPT's effort slider, `chatgpt-33`, is a custom
  surface; a menu is native and fits ACP's discrete options.)
- Mic (36 pt, `fill`): starts system dictation into the field
  (`UITextInputMode` dictation via the keyboard is the fallback; prefer on-device
  `SpeechAnalyzer` streaming into the field, live text in `label2` until final).
- Primary (36 pt): `idle-empty` = `arrow.up` on `fill`, glyph `label3` (disabled);
  `idle-text` = `arrow.up` on `accent`, glyph `onAccent`; `running` = `stop.fill` on `accent`;
  `queued` (text while running) = `arrow.up` on `accent` with a 2 pt `label2` ring; long-press
  → menu "Queue (send after this turn)" / "Steer now (interrupt)" (Codex "Follow-up behavior:
  Queue", `chatgpt-14-codex-settings`). Symbol swap uses
  `.contentTransition(.symbolEffect(.replace))`.
- Return key: inserts a newline; send is the button (all three apps). Hardware keyboard:
  Return sends, Shift-Return newline, Cmd-. stops.
- After send: field clears, keyboard dismisses if Settings > Composer > "Dismiss keyboard after
  sending" is on (default on, Codex setting), composer collapses to the capsule.
- Collapsed: capsule 48 h, side margin 20: `+` glyph (no circle), placeholder "Follow up",
  mic, primary (ChatGPT `chatgpt-17`). Tap anywhere → expands (`smooth`) and focuses.
- Disabled: whole card at 50% opacity, placeholder replaced by the reason ("Mac offline",
  "Waiting for permission"); tap shows the reason as a toast.
- Keyboard: composer bottom = keyboard top - 8 (ride the keyboard transaction). Interactive
  keyboard dismissal: `.scrollDismissesKeyboard(.interactively)` on the transcript.

### 4.4 Message rows

- `UserBubble`: section 2.3 metrics; `bubble` fill; `body` text; images above text as a
  stacked strip (radius 16). Long press: native context menu with header "Today, 11:51 AM"
  (`chatgpt-19`), items Copy, Select text, Edit and resend (only last), Share.
  Select text: replaces the bubble with a selectable `Text` and shows the system edit menu
  (`chatgpt-20-select-text`).
- `AssistantBlock`: full width, 20 pt margins, markdown per 2.2; no avatar, no name (all
  three). Agent name appears only in the toolbar title.
- `ActionRow` (after a completed assistant turn): `IconAction`s copy, share, retry, more; 4 pt
  gap, 12 pt above; trailing `meta` duration ("41s", Grok `5.47s`). More menu header
  "Today, 11:51 AM", items: Copy as Markdown, Fork from here (new session), Retry, Report issue
  (`chatgpt-25-answer-more-menu`, `grok-08-more-menu`).
- Footer disclaimer: none (Claude's "Claude is AI and can make mistakes" is the model vendor's).
- Suggested follow-ups (Grok `grok-07`): not in v1.

### 4.5 Working indicator

`WorkingLabel`: "Working" in `body` `label2` with a moving highlight (a `LinearGradient` mask
`label2` → `label` → `label2`, 40% band, sweeping left to right with `shimmer`), followed by
elapsed time in `meta` once over 5 s ("Working · 12s"). Replaced in place by the first streamed
block. Position: where the next assistant block will start (`chatgpt-16-working-shimmer`).

### 4.6 Code card

- `codeBg`, radius 20, no border (dark) / 0.5 pt `separator` border (light).
- Header 40 pt: leading language icon (`chevron.left.forwardslash.chevron.right` 13) + label
  (`codeLabel`, "Swift", "Diff", "Bash"); trailing copy `IconAction` (`grok-05`,
  `chatgpt-17`).
- Body: `codeBody`, horizontal `ScrollView` (no wrap by default; Settings > Terminal >
  "Wrap code" applies to transcript code too, Codex "Wrap code diff lines"), syntax colors from
  2.1, no line numbers, padding 16 h / 4 top / 16 bottom.
- Height cap 480 pt in transcripts; beyond that the body is clipped with a 48 pt gradient fade
  to `codeBg` and a "Show all N lines" `TextCTA` that opens the file preview viewer.
- Streaming: render progressively; never re-highlight more than the last 50 lines per tick.
- Long press: menu Copy, Copy as Markdown, Open in viewer, Share (Grok `grok-08` "Copy Plaintext").

### 4.7 Tables

Markdown tables render as a grid inside a horizontal `ScrollView` that escapes the 20 pt
margins (bleeds to the screen edges, content inset 20) (`chatgpt-18-table-hscroll`). Header row
`subheadline` semibold; cells `subheadline`; row separators 0.5 pt `separator`; column min width
96, max 260, cell padding 12 h / 10 v. Inline code inside cells keeps mono.

### 4.8 Sheets

- Native sheets with `.presentationDetents`; partial heights get floating glass from the system.
- Header: 44 pt glass circle `xmark` leading, centered title (`screenTitle`), optional trailing
  circle (Claude settings "i", `claude-07-settings`). Grabber visible for resizable sheets only.
- Primary action docked at the bottom (or above the keyboard) as a large `PrimaryCapsule`,
  disabled until valid (`chatgpt-29-new-project-sheet`, `chatgpt-09-codex-pair-manual`).
- Swipe down dismisses unless the sheet holds unsaved input (`.interactiveDismissDisabled(dirty)`
  with a confirmation dialog on X).

### 4.9 Menus and alerts

Native `Menu`, `contextMenu`, `confirmationDialog` (springs from its source on iOS 26) and
`alert`. Menu sections with header text ("Manage", "Usage remaining" in `chatgpt-07`). Never a
custom popover. Alerts follow `claude-04-new-session-alert`: title, body, two buttons.

---

## 5. Launch, onboarding, sign-in

### 5.1 Launch screen

- `UILaunchScreen` in Info.plist: `UIColorName` = `LaunchBackground` (#000000 dark /
  #FFFFFF light), `UIImageName` = `LaunchMark` (the app icon's chevron layer from
  `AppIcon.icon`, glow included: a 70 x 86 pt image with the chevron 72 pt tall at its center;
  `scripts/generate-launch-mark.swift`), centered. No text, no spinner. (ChatGPT, Claude and Grok all show only their mark
  on their background.)
- `LaunchHandoff` (first SwiftUI frame): the same mark at the same position. When auth resolves
  (Keychain read, < 300 ms typical) to a signed-in destination, the mark scales 1.0 → 0.92 and
  fades out over `snap` while the destination fades in with `gentle`. To Welcome there is no
  fade: Welcome draws the launch mark itself on its first frame and animates it (5.2). If auth
  takes > 1 s, show nothing extra; never a spinner on launch.

### 5.2 Welcome (signed out)

No carousel and no feature copy. The structure follows Claude's welcome
(`verify/login-claude-reference.md`): a small brand lockup at the top, one illustration and one
serif line in the middle, the sign-in stack at the bottom. Layout on `bg`:

- Lockup, centered under the status bar (6 pt): the cmux chevron (the launch mark's image,
  the app icon's chevron layer), 22 pt tall, 7 pt gap, "cmux" in `welcomeWordmark` (`title2` semibold) `label`.
- Hero, centered in the space between the lockup and the buttons: the illustration (a Mac and an
  iPhone drawn as one 3.3 pt round-capped `label` line, 291 x 233 pt), a gradient `>_` prompt on
  the Mac's screen and the gradient chevron (30 pt, soft `#2AA0F9` glow) on the phone's screen.
  26 pt below it, centered `welcomeTitle` (`title`, serif, regular) `label`: "Your Macs, in your
  pocket."
- Bottom stack, 20 pt margins, 10 pt spacing, all 52 h capsules (ChatGPT's order, Apple first and
  no smaller than the others, as the HIG requires):
  1. "Continue with Apple": solid `accent` (white in dark, black in light), `onAccent` text.
  2. "Continue with Google": `surface` fill (dark) / `fill` (light), `label` text, full-color
     Google "G" at 18 pt.
  3. "Continue with GitHub": same style, GitHub mark template in `label`.
  4. "Continue with email": same style, `envelope` symbol.
- Footer `caption2` `label3`, centered: "By continuing, you agree to the Terms and Privacy
  Policy." with the two links.
- Cold-launch intro, about 5 s, one clock (`t` from the handoff; it advances with rendered frames,
  each step capped at 1/30 s, so a stalled main thread pauses it instead of skipping it):
  - 0.04-0.68 s: the launch mark (72 pt, centered, `label`) glides into the lockup slot and
    shrinks to 22 pt (ease-out quint), taking the gradient over 0.12-0.6 s. "cmux" fades in and
    slides 8 pt right over 0.3-0.85 s.
  - 0.08-0.5 s: the headline fades in, un-blurs 8 → 0 and rises 8 pt. 0.12-0.65 s: the buttons
    fade in and rise 14 pt, 45 ms apart; the footer fades in over 0.35-0.75 s. Buttons work from
    their first visible frame; tapping one mid-intro does not stop the intro.
  - 0.3-1.55 s: the Mac is drawn (stroke trim, ease in-out); 1.05-2.0 s the phone; 1.55-1.95 s
    the prompt.
  - 1.95-3.3 s: a network of gradient nodes grows from the prompt over the gap to the phone,
    each edge growing in 0.25-0.35 s and each node popping (ease-out back) as its edge arrives.
    3.1-4.2 s: the nodes sway (3.6 pt). 4.0-4.7 s: they fold into the phone's screen, farther
    nodes first, and fade.
  - 4.4-5.15 s: the chevron blooms on the phone (scale 0.25 → 1 with overshoot) and its glow comes
    up. The intro is settled at 5.2 s and the timeline stops.
  - Idle (Claude's welcome has one idle event): 4 s after settling and then every 9 s, three
    small dots run along the network's path from the Mac to the phone (1.35 s) and the chevron
    beats (scale 1.09, glow up). Nothing else moves.
  - Plays once per process. After sign-out Welcome crossfades in, settled.
  - Reduce Motion: the launch mark crossfades into the settled screen over 0.35 s; no idle
    pulse.

### 5.3 OAuth (Apple, Google, GitHub)

- Apple: native `ASAuthorizationAppleIDProvider` sheet; on success → Stack Auth exchange via
  `CmuxMobileAuth`. Google and GitHub: `ASWebAuthenticationSession` (ephemeral session off, so existing
  browser sign-in is reused), callback `dev.cmux.mobile://auth`.
- While exchanging: the tapped button shows a `ProgressView` in place of its icon; other buttons
  disable (opacity 0.5). Errors: inline text under the stack in `danger` `footnote`, plus
  `.error` haptic; user cancel is silent.

### 5.4 Email code

Sheet, `.presentationDetents([.large])`, keyboard up immediately. Background `sheet` in dark,
plain `bg` (white) in light, where `sheet` and `surfaceRaised` are the same gray and the field
and code boxes would vanish:

1. Step "Email": leading `sheetTitle` "Continue with email", `rowSubtitle` "We'll send you a
   6-digit code." `TextField` 52 h, radius 14, `surfaceRaised` fill, `.textContentType(.emailAddress)`,
   `.keyboardType(.emailAddress)`, autocapitalization off. Docked CTA "Send code" (disabled until
   the email parses).
2. Step "Code" (push within the sheet, horizontal slide): "Check your email", "Enter the code we
   sent to name@example.com." Six boxes, each 48 x 56, radius 12, `surfaceRaised`, `title2`
   mono digits, 8 pt gaps, centered; a hidden `TextField` with `.textContentType(.oneTimeCode)`
   drives them (Mail autofill works). Focused box: 2 pt `label` stroke. Auto-submits on the 6th
   digit. Invalid: `shake` + `.error` haptic + boxes clear. "Resend code" `TextCTA` disabled with
   a 30 s countdown ("Resend in 0:24"). "Use a different email" goes back.
   (Same box component as pairing, 5.6, with a 4+4 layout there.)

### 5.5 Post sign-in setup (first run only)

Each step is a full-screen page in a `NavigationStack` with a back circle; progress is implicit
(no dots). Skippable steps have a "Not now" `TextCTA` under the primary.

1. Team (only if the user has 2+ teams and none chosen): list of `SidebarTeamRow`s, tap to pick.
   Zero teams: "Create your team" with a name field and the color/emoji editor inline.
2. Pair a Mac (only if the team has no Macs owned by the user): the Codex setup screen
   (`chatgpt-10-codex-setup-onboarding`): 48 pt `desktopcomputer` glyph, title "Set up cmux on
   your Mac", two explanatory rows (icon 22 + `body`): "Install cmux on your Mac and sign in with
   this account." / "Your Mac appears here when it's online." Primary "I'm signed in on my Mac"
   (goes to 5.6), secondary glass "Email me a download link".
3. Notifications priming: glyph `bell.badge` 48, title "Know when an agent needs you", rows:
   "Questions and permission requests", "Finished tasks", "Live Activities for running
   agents". Primary "Turn on notifications" (system prompt), "Not now".
4. Done → Shell, Home tab, with a one-time crossfade (`gentle`).

### 5.6 Pairing a Mac (Codex flow, `chatgpt-05` to `chatgpt-11`)

1. Empty state (Workspaces when no Macs, `chatgpt-11-codex-connect-empty`): glyph
   `desktopcomputer` 28, title "Connect your Mac", body "Open cmux on your Mac and choose Pair
   iPhone to get a code.", primary inline "Scan QR code", `TextCTA` "Enter code manually".
2. QR scanner (push, `chatgpt-08-codex-qr-scan`): black background, camera viewport 280 x 280
   centered (radius 40 continuous), four `warning` corner guides (L shapes 36 pt legs, 4 pt
   stroke, round caps, inset 24), title under it "Scan the QR code on your Mac" (`headline`).
   Bottom: secondary glass large "Pair manually instead". Camera permission denied: viewport shows
   `camera.fill` and "Allow camera access in Settings" with a `TextCTA` "Open Settings".
   On detection: corners animate to the code bounds (`snappy`), `.success` haptic, then pair.
3. Manual (sheet `.medium`, `chatgpt-09-codex-pair-manual`): "Pair manually", "Enter the code
   shown on your Mac.", 4 + 4 boxes (42 x 52 each, 6 pt gaps, a `label3` dash between groups),
   uppercase alphanumerics excluding 0/O/1/I; paste fills all. Primary "Pair" disabled until 8.
4. Pairing in progress: primary shows a spinner; success: sheet dismisses, the new Mac row
   appears in Workspaces with `snappy`, toast "Paired with <Mac name>".
5. Failure: inline `danger` footnote under the boxes ("That code expired. Get a new one on your
   Mac."), `shake`, `.error`.

---

## 6. Agent chat (`CmuxMobileAgentChat`) and Home (Chief)

Home's Chief conversation is the same screen with a different toolbar and without the model
pill (Chief model is configured on the Mac). Everything below applies to both unless noted.

### 6.1 Toolbar

- Agent chat (pushed): system back; principal: two-line title button, line 1 agent session
  title (`headline`, truncates middle), line 2 `meta` "<agent> · <workspace>" with a 6 pt
  `StatusDot`; tap → menu: Rename, Open terminal, Files, Changes (diff viewer), Copy session ID,
  section "Mode" (permission mode picker). Trailing glass capsule: `square.and.pencil` (new
  session in this workspace) + `ellipsis` (Share transcript, Archive, Stop agent (destructive)).
  Pattern: `claude-09-chat`, `chatgpt-21-chat-more-menu`.
- Home: leading drawer circle; principal "Chief" (`headline`); trailing capsule
  `square.and.pencil` (new Chief thread) + `clock.arrow.circlepath` (thread history sheet).

### 6.2 Transcript layout

- `ScrollView` + `LazyVStack(spacing: 0)` with `.defaultScrollAnchor(.bottom)` and
  `.scrollPosition`; 20 pt margins; turn spacing 24 pt; user bubble to assistant 16 pt; 
  bottom content inset = composer height + 16.
- Empty (new session): centered glyph (agent avatar 48) + `title3` "What should <agent> do?"
  + `rowSubtitle` "<workspace> on <Mac>". Composer focused only if the user tapped "new".
  (`claude-05-composer-focused`, Grok "Ask Anything" home `grok-01`.)
- History loads newest-first in pages of 50 turns; older pages prepend while keeping the scroll
  offset (anchor on the first visible turn id). Top-of-history: `meta` "Session started
  <date>".
- Follow mode: while at bottom (within 80 pt), new content keeps the view pinned (no animation;
  snapping beats smoothing for streaming). Once the user scrolls up by more than 80 pt, follow
  stops and the jump circle appears.

### 6.3 Streaming

- Render committed markdown blocks natively; the in-progress tail block re-renders each tick.
- No per-word or per-glyph fade (Hermex measured it as a main source of stutter at 48 ms update
  intervals; t3code iOS has none). New blocks (paragraph, list item, code card) appear with a
  0.15 s opacity fade only; text inside a block appears as it arrives. Coalesce updates to at most
  one layout pass per display frame (`CADisplayLink`-driven buffer, 60 Hz cap on ProMotion).
- Stop: primary shows `stop.fill`; tapping sends ACP `cancel`; the partial turn ends with
  `meta` "Stopped" in `label3`.

### 6.4 Tool calls (Claude Code / Codex / T3 Code style)

- `ToolRow`: 32 pt min height, leading 15 pt symbol (2.5) in `label2`, then `toolRow` text:
  verb + object, object in mono, e.g. "Read `Sources/App/User.swift`", "Ran `swift test`",
  "Edited `User.swift`  +12 −4" (counts in `diffAddText` / `diffDelText` `meta`), "Searched
  for `displayName`". Trailing `chevron.right` 11 `label3`, rotates 90 degrees when expanded.
- Running: verb shimmers (`WorkingLabel` style) and a 12 pt `ProgressView` replaces the
  chevron. Failed: symbol `exclamationmark.triangle.fill` in `danger`, text stays `label2`.
- Grouping: consecutive tool calls with no prose between collapse into one summary row "Read 4
  files, ran 2 commands" (expands to the list). Default collapsed once the turn finishes;
  expanded while running (latest call visible).
- Expanded: a code card (4.6) with the call's output; bash shows `$ command` header line in
  `label2` then output; capped at 12 lines with "Show all". Edits show the inline diff (6.8).
- Expand/collapse with `smooth`.

### 6.5 Permission prompts

When the agent requests permission (ACP `session/request_permission`):

- In the transcript: `PermissionCard` at the turn's end: `surface` card radius 20, padding 16;
  header `hand.raised.fill` in `warning` + `headline` "<Agent> wants to run a command"
  (or "edit 2 files", "fetch a URL"); body: the command in a compact code card (max 6 lines)
  or the file list with counts; `meta` working directory.
- The composer is replaced (crossfade `snap`, height animates `smooth`) by an action bar in the
  same glass card: three stacked full-width buttons 48 h: "Allow once" (`PrimaryCapsule`),
  "Always allow <tool> in this workspace" (`SecondaryCapsule`), "Deny" (`SecondaryCapsule`,
  `danger` text). Options come from the ACP request (`allow_once`, `allow_always`,
  `reject_once`, `reject_always`); render what the agent offers, in that order.
  A "Reply instead" `TextCTA` restores the composer to send guidance with a deny.
- Arrival: card slides up 16 pt + fades with `snappy`; `.warning` haptic if visible.
- Resolved: card collapses (`smooth`) into a `ToolRow` with `checkmark.circle` "Allowed
  once" / `xmark.circle` "Denied".
- Notification when backgrounded: actionable push with "Allow once" / "Deny" actions; Live
  Activity shows "Needs permission".

### 6.6 Questions (AskUserQuestion / ACP elicitation)

- `QuestionCard`: `surface` radius 20, padding 16; header `questionmark.bubble` + question text
  (`headline`); optional `rowSubtitle` context.
- Single choice: options as 48 h rows inside the card, radius 14, `fill`; selected:
  `fillSelected` + trailing `checkmark` (`label`). Multi-select: trailing `circle` /
  `checkmark.circle.fill`. Last row "Other..." expands an inline text field.
- Submit: `PrimaryCapsule.inline` "Answer" trailing-aligned, disabled until valid. Sends,
  `.impact(.light)`, collapses to a summary: `meta` "You answered" + the answer in a small
  `bubble` (right-aligned, like a user bubble).
- Multiple questions in one request: paged horizontally inside the card with "1 of 3" in
  `meta` and Next; Answer on the last.
- The same component renders inline in the Feed (section 8.4).

### 6.7 Plans

- `PlanCard`: `surface` radius 20; header `list.bullet.clipboard` + "Plan" (`headline`) +
  trailing `meta` step count; body markdown capped at 10 lines with fade + "Show full plan"
  (opens a `.large` sheet with the full plan and the same actions); todo-style plans render each
  step with a 16 pt status glyph (`circle`, `circle.dotted` animated while in progress,
  `checkmark.circle.fill` in `success`).
- Actions when the agent awaits approval (ExitPlanMode / plan mode): "Approve plan"
  (`PrimaryCapsule.inline`), "Keep planning" (`SecondaryCapsule.inline`); the composer stays
  available to send feedback.
- Live todo updates animate checkmarks with `.symbolEffect(.bounce)` once.

### 6.8 Diffs in the transcript

- Edit tool results show `DiffSnippet`: code card with header "Edited `User.swift`" + `+12 −4`
  + trailing `arrow.up.right` "Open"; body unified lines in `codeBody` with `+`/`−` markers,
  text-only colors (`diffAddText`, `diffDelText`; no row fills; ChatGPT `chatgpt-17`), context
  lines `label2`, max 12 lines then "Show N more lines". Tap header → diff viewer (section 12)
  scrolled to that file.
- Turn summary: after a turn with edits, one `ChangesRow`: `plus.forwardslash.minus` "3 files
  changed +40 −12" → diff viewer for the turn.

### 6.9 Jump to bottom

36 pt glass circle `arrow.down` (15 semibold), centered horizontally, 12 pt above the composer,
inside the composer's `GlassEffectContainer` with a shared `glassEffectID` namespace so it
emerges from the composer. Visible when distance from bottom > 80 pt; appear/disappear: scale
0.85 ↔ 1 + opacity with `snap`. Tap: scroll to bottom with `.smooth(duration: 0.35)` and
re-enable follow. While streaming and not following, the circle shows a 2 pt `label` ring
pulsing (new content below).

### 6.10 Comparison checklist (agent chat)

| Check | Reference |
| --- | --- |
| Toolbar circle + title + capsule spacing | `claude-09-chat`, `chatgpt-17-diff-table-stream` |
| Empty session | `claude-05-composer-focused`, `grok-01-home-keyboard` |
| Composer idle, focused, typed | `claude-09-chat`, `claude-05-composer-focused`, `grok-03-composer-typed` |
| Composer running (stop) | `grok-05-streaming-code`, `chatgpt-16-working-shimmer` |
| Composer collapsed "Follow up" | `chatgpt-16-working-shimmer`, `chatgpt-17-diff-table-stream` |
| `+` menu | `chatgpt-04-plus-menu`, `grok-02-plus-menu` |
| Model/effort control | `claude-05-composer-focused`, `chatgpt-33-effort-slider`, `chatgpt-35-configure-sheet` |
| User bubble | `grok-05-streaming-code`, `claude-09-chat` |
| Working shimmer | `chatgpt-16-working-shimmer` |
| Code card | `grok-05-streaming-code`, `grok-06-scroll-edge-top` |
| Inline diff | `chatgpt-17-diff-table-stream` |
| Table + horizontal scroll | `chatgpt-17-diff-table-stream`, `chatgpt-18-table-hscroll` |
| Bubble context menu, select text | `chatgpt-19-bubble-context-menu`, `chatgpt-20-select-text` |
| Answer action row + more menu | `chatgpt-24-answer-end-actions`, `chatgpt-25-answer-more-menu`, `grok-07-answer-end-actions`, `grok-08-more-menu` |
| Jump to bottom | `chatgpt-17-diff-table-stream`, `grok-05-streaming-code` |
| Top scroll edge under chrome | `grok-06-scroll-edge-top`, `chatgpt-23-sidebar-selected-expanded` |
| Inline failure card | `grok-09-failure-paywall-card` |
| Chat more menu | `chatgpt-21-chat-more-menu` |
| Alert style (mode change notice) | `claude-04-new-session-alert` |

No reference exists for tool rows, permission and question cards, or plans: compare against
Claude's and Codex's own mobile session views when captured (TapKit only with explicit
permission), and against Cursor iOS / T3 Code App Store screenshots.

---

## 7. Loading, empty, failure, offline

### 7.1 Loading

- Lists: skeleton rows matching the real row geometry: `surfaceRaised` rounded rects (title
  bar 60% width x 14 h radius 7; subtitle 40% x 11 h), `shimmer` gradient sweep (a 30% wide
  `#FFFFFF` @ 6% band, dark; `#000000` @ 4%, light). Show only after 250 ms (no flash for fast
  loads); 6 rows max.
- Transcript: `WorkingLabel` reading "Loading" centered at the top of the empty transcript
  until the first page arrives.
- Buttons: inline spinner in place of the label (4.1). Never full-screen spinners.
- Pull to refresh: system `.refreshable` on Workspaces, Feed, Files.

### 7.2 Empty states

One component `EmptyState(symbol:, title:, message:, primary:, secondary:)`, vertically centered
in the available area (above the composer when one exists): symbol 28 pt `label`, 16 pt gap,
`emptyTitle`, 6 pt gap, `rowSubtitle` centered, max width 300, 20 pt gap, `PrimaryCapsule.inline`,
12 pt gap, `TextCTA`. (`claude-02-code-empty`, `chatgpt-11-codex-connect-empty`,
`chatgpt-27-library-folders-empty`, `chatgpt-28-projects-empty`, `chatgpt-22-uploaded-files-empty`.)

| Screen | Symbol | Title | Message | Primary | Secondary |
| --- | --- | --- | --- | --- | --- |
| Workspaces, no Macs | `desktopcomputer` | Connect your Mac | Open cmux on your Mac and choose Pair iPhone to get a code. | Scan QR code | Enter code manually |
| Workspaces, Macs offline | `moon.zzz` | Your Macs are asleep | Wake a Mac or open cmux on it to see its workspaces. | (none) | Show offline Macs |
| Mac with no workspaces | `square.stack.3d.up` | No workspaces | Create one on your Mac or start one here. | New workspace | |
| Feed empty | `bubble.left.and.text.bubble.right` | Nothing yet | Agent updates, questions and finished tasks show up here. | (none) | |
| Feed filter empty | `line.3.horizontal.decrease` | No matching events | Try another filter. | Show all | |
| Files empty | `folder` | This folder is empty | | | |
| Diff, no changes | `checkmark.circle` | No changes | The working tree is clean. | | |
| Search, no results | `magnifyingglass` | No results for "x" | Check the spelling or try a new search. | | |

### 7.3 Failure

- List-level (`chatgpt-06-codex-error-state`): `EmptyState` with `cloud` (or
  `desktopcomputer.trianglebadge.exclamationmark` for a Mac), title "Couldn't load workspaces",
  message "Check your connection and try again.", primary "Retry". Retry shows a spinner in the
  button, keeps the message visible.
- Inline in transcript (`grok-09-failure-paywall-card`): `FailureCard`: `bg` with 1 pt
  `separator` stroke, radius 20, padding 16; `clock` / `exclamationmark.triangle` 17 pt,
  `headline` title ("Agent stopped", "Couldn't send"), `rowSubtitle` body, then a large
  `PrimaryCapsule` ("Retry"). Message send failures mark the user bubble with a 15 pt `danger`
  `exclamationmark.circle.fill` leading it; tap → menu "Retry", "Delete".
- Never show raw errors. Copy uses cmux terms ("Cloud service", "Request ID"); a "Details"
  `TextCTA` shows Request ID / Trace ID in a sheet with Copy.

### 7.4 Offline and reconnecting

- Connection banner (global overlay under the toolbar, centered, 8 pt below the toolbar line):
  glass capsule 36 h, padding 14, `footnote` semibold:
  - Reconnecting: small `ProgressView` + "Reconnecting to <Mac>…". Shown only after 1.5 s of
    disconnection (most blips heal silently).
  - Offline (no network): `wifi.slash` + "You're offline".
  - Mac offline: `moon.zzz` + "<Mac> is offline". Tap → sheet with last seen time and "Wake
    with Wake-on-LAN" (when supported, future) / "Retry".
  - Recovered: `checkmark` + "Connected" for 1.5 s then hides.
  Enter/exit: move from y - 12 + opacity, `snappy`. Never more than one banner.
- Stale data: lists keep the last snapshot visible with rows at full opacity; a `meta` "Updated
  2m ago" appears in the section header. Composers disable (4.3) with the reason.
- Terminal: on disconnect the surface dims to 60% under a centered `FailureCard`-style glass
  card "Reconnecting…" with a spinner; on reconnect the screen redraws from the server snapshot
  (no local replay).
- Toasts (`CmuxMobileToast`): glass capsule at the top under the toolbar, `footnote` text, optional
  leading symbol, 3 s, swipe up to dismiss; one at a time, newest replaces.

---

## 8. Feed (`CmuxMobileFeed`)

A Twitter/X-style timeline of agent events across the team: turns finished, questions,
permission requests, errors, PR events.

### 8.1 Screen

- Toolbar: leading drawer circle, principal "Feed", trailing `line.3.horizontal.decrease`
  circle (filter menu: Picker inline All / Needs you / Finished / Errors, section "Macs" with a
  toggle per Mac; pattern `chatgpt-31-filter-menu`).
- Chip row under the toolbar (scrolls with content): All, Needs you (with count), Finished,
  Errors (4.1 `Chip`). Chips mirror the filter menu.
- `List(.plain)` with 0.5 pt separators from the text column (4.2.1), `bg`. New events above the
  viewport: glass capsule "↑ 3 new" centered under the toolbar; tap scrolls to top with `smooth`.
- Tab bar stays fully visible while the list scrolls (3.2).

### 8.2 Cell

```
[av]  Claude Code · cmux-next / feat-feed · 2m          ···
      ╭───────────────────────────────╮
      │ Fix the flaky tab restore test│   ← quote bubble (the prompt)
      ╰───────────────────────────────╯
      Fixed `TabRestoreTests`: the restore raced the
      session load. Added an await on `ready`…
      Show more
      [ inline answer UI for questions ]
      💬 Reply    ↗ Open    ⧉ Copy
```

- Padding 16 h / 12 v; avatar column 40 pt (agent avatar 40, 4.2) + 12 pt gap.
- Header line (`subheadline`): agent name semibold, then `label2` "· <workspace> · <relative
  time>" (truncates the workspace first); trailing `ellipsis` `IconAction` (menu: Open tab,
  Mute this workspace, Copy link, Mark as read).
- Quote bubble (iMessage reply style): the prompt the event responds to, `bubble` fill at 100%
  dark / 100% light, radius 16, padding 12 h / 8 v, `subheadline` `label2`, max 3 lines with tail
  truncation, leading-aligned, max width 90% of the column. A 1.5 pt `separator` connector
  curves from the bubble's bottom-leading corner down into the body (iMessage thread line), 12 pt
  long. Tap the bubble → expands to full prompt (`smooth`).
- Body: markdown. Per PLAN, rendered in `WKWebView` (shared `WKProcessPool`, one
  non-scrolling web view per visible cell, height measured via `ResizeObserver` message; cells
  pre-size with an estimated height to avoid jumps). CSS mirrors 2.2 tokens through CSS
  variables; code blocks use the code card style. Collapsed height cap: 8 lines of body
  (~ 8 x 28 = 224 pt) with a 32 pt gradient fade to `bg`, then "Show more" (`subheadline`
  semibold `label`); expanded shows "Show less". Expand animates the cell height with `smooth`
  (List row height animation via `withAnimation`).
- Event kinds add a status chip before the body: "Needs permission" (`warning` dot), "Question"
  (`questionmark.bubble`), "Failed" (`danger`), "Finished" (no chip; default).
- Inline answer UI (questions and permissions): the `QuestionCard` / permission actions
  (6.5, 6.6) rendered inside the cell under the body, full column width. Answering does not
  open the tab; the cell updates to "You answered: …" and the event's badge clears.
- Footer actions row, 32 pt, `IconAction`s with labels in `meta`: Reply (`bubble.left`: opens
  an inline composer in the cell, keyboard up, sends into that tab's agent), Open
  (`arrow.up.right.square`), Copy (`doc.on.doc`), Share. X-style spacing: evenly distributed
  across the column, max 4.
- Tap anywhere else on the cell → open the event's tab: push the Workspace's tab (agent chat or
  terminal) inside the Feed stack, scrolled to the event's turn. Highlight row `fillPressed` on
  touch down.
- Swipe actions (trailing only, 3.3 swipe rules), outermost first: pending permission "Deny"
  (`xmark.shield`, destructive red) and "Allow" (`checkmark.shield`, system green; a full swipe
  never allows); pending question "Decline" (`xmark`, destructive red) and "Answer"
  (`arrowshape.turn.up.left`, system blue); every other event "Done" (`checkmark`, system purple,
  removes the row with the Undo bar) and "Read"/"Unread" (`envelope.open`/`envelope.badge`,
  system blue). The context menu and the `ellipsis` menu hold Open tab, Copy, Mark as
  read/unread, Done and Mute this workspace.

### 8.3 Comparison checklist (Feed)

| Check | Reference |
| --- | --- |
| Filter chips | `chatgpt-26-library-grid`, `chatgpt-27-library-folders-empty` |
| Filter menu | `chatgpt-31-filter-menu`, `chatgpt-07-codex-title-menu` |
| Card rows of tasks (layout density) | `chatgpt-30-scheduled` |
| Quote bubble color and radius | `claude-09-chat`, `grok-05-streaming-code` (bubble) |
| Empty | `chatgpt-22-uploaded-files-empty` |
| Row context menu | `grok-15-row-context-menu` |
| Inline answer, permission | no capture; compare with Cursor iOS and Claude mobile notifications (online screenshots) |

---

## 9. Settings (`CmuxMobileSettings`)

Tab root, `NavigationStack`, toolbar: leading drawer circle, principal "Settings". `List`
`.insetGrouped` on `bgGrouped`. Section headers use the system iOS 26 style (sentence case,
`label2`). Sub-pages push with the system edge swipe back (ChatGPT/Claude both support it).

| Section | Rows |
| --- | --- |
| (Account card, no header) | Avatar 40 (initials) + name (`body` semibold) + email (`footnote` `label2`) + chevron → Account page (name, email, linked sign-in methods with badges Apple / Google / GitHub / Email, "Delete account" red at the bottom). Pattern `claude-07-settings`, `grok-12-settings`. |
| Team | "<Team name>" row with team avatar (28) → Team page: Color and icon (3.4), Members (read-only list from Stack, owner badge), Invite to team, Leave team (red). Footer: "Color and icon are yours only; teammates choose their own." (prefs are per user per team, PROTOCOL.md) |
| Connection | Transport: inline `Picker` menu "WebRTC" / "WireGuard" (value trailing with `chevron.up.chevron.down`, like Codex "Follow-up behavior: Queue"). Footer: "Switching reconnects to your Macs." / Paired Macs → page: rows with `StatusDot` + name + `footnote` "Online · WebRTC direct" / "Last seen 3h ago", swipe to Unpair; "Pair a Mac" row with `plus` in `label` (not blue; Codex uses blue "Add connection", `chatgpt-14`); "Disconnect all" trailing in the section header as `label2` text button. / Show connection details (toggle: shows path type, RTT, relay in the terminal title menu). |
| Terminal | Font size (stepper 9–24, live preview row in the terminal theme), Theme (picker of Ghostty themes with swatches; default follows the Mac's theme), Key bar (page: reorder and toggle keys, 10.4), Composer: "Dismiss keyboard after sending" (toggle, on), "Follow-up while running" (Queue / Steer), "Wrap code and diff lines" (toggle, off), "Key clicks" (toggle, on). |
| Appearance | Three tiles Light / Dark / System (`claude-08-settings-bottom`): 96 x 64 rounded previews radius 14, selected 2 pt `label` stroke and the label in `label` semibold (Claude uses blue; we use label). Haptic feedback toggle. |
| Notifications | Allow notifications (system status row → opens iOS Settings if denied), Questions and permissions (toggle), Finished tasks (toggle), Errors (toggle), Live Activities ("One per agent" / "Only when waiting" / "Off", menu picker; Codex "Live Activities: One per remote"). |
| Security | Require Face ID (toggle; footer "Require Face ID or passcode to open mobile on this device.", `chatgpt-15-codex-settings-bottom`). |
| About | Help, Report a problem (attaches diagnostics + Request ID), Terms of Use, Privacy Policy, Acknowledgements. |
| (Log out, no header) | "Log out" alone, `danger`, leading `rectangle.portrait.and.arrow.right` in `danger` (`chatgpt-13`, `claude-08`, `grok-13`). Confirmation dialog: "Log out of mobile?" destructive "Log out". |
| Footer | Centered `caption2` `label3`: cmux mark 16 pt, "Version 1.0 (123) · <tag>" (`grok-13-settings-bottom`). |

Comparison checklist (Settings): `claude-07-settings`, `claude-08-settings-bottom`,
`chatgpt-13-settings-bottom`, `chatgpt-14-codex-settings`, `chatgpt-15-codex-settings-bottom`,
`grok-12-settings`, `grok-13-settings-bottom`. Check: row height 54, group radius, icon
alignment, red Log out alone, toggle tint green, footers.

---

## 10. Terminal screen (`CmuxMobileTerminal`)

References: Termius (gesture arrows with gears, keyboard add-on, hide-keyboard action), Blink
(smart keys: modifiers, arrows, scrollable middle; hidden with a hardware keyboard), Moshi
(Ctrl/Esc/Tab/arrows row, tmux shortcuts, hold-to-talk), La Terminal (agent-centric, native
dictation). Codex and our own REFERENCES.md: "Terminal screen = chat screen".

### 10.1 Chrome

- Ghostty surface full-bleed behind everything; background = terminal theme background (this is
  the one screen where chrome derives from the terminal theme: glass picks up the tint
  naturally; key bar caps use `ThemeTokens.chromeBackground`).
- Toolbar (glass, system): back; principal: tab title (`headline`, e.g. "claude — cmux-next")
  + `chevron.down` 11 → menu: tabs of this workspace (icon by kind, checkmark on current), "New
  terminal tab", "All tabs" (grid sheet); section with connection details when enabled (e.g.
  "WebRTC · direct · 23 ms"). Trailing capsule: `keyboard` toggle + `ellipsis` (Copy mode,
  Paste, Clear, Font size −/+, Send Ctrl-C, Open files, Changes).
- Non-TUI (shell, scrollback): default soft top edge effect. TUI (alt screen, e.g. Claude Code,
  vim): hard edge (`.hard`) and the grid's top inset fixed to the toolbar bottom so rows never
  jump.
- Scroll: native momentum scrolling through scrollback (Ghostty viewport), 120 Hz; scroll-to-
  bottom circle as in 6.9 when scrolled up in non-TUI mode.

### 10.2 Bottom stack (pinned to the keyboard)

From bottom to top, inside one `GlassEffectContainer(spacing: 8)`, side margin 8:

1. Key bar (only while the keyboard is up; hidden when a hardware keyboard is attached, like
   Blink and Termius): 44 h glass capsule, horizontally scrollable middle with fixed ends:
   - Leading fixed: `esc` (Esc), `ctrl` (sticky modifier: tap = one-shot, highlighted
     `fillSelected`; double tap = lock, `accent` fill), `alt`.
   - Middle (scrolls): `tab`, `⇧tab` (Termius added Shift-Tab for Claude Code modes), `|`, `~`,
     `/`, `-`, `` ` ``, `{`, `}`, `[`, `]`, `^C`, `^D`, `^Z`, `^L`, `^R`, tmux prefix (`^B`).
     Each key cap 40 x 34, radius 10, `fill`, label `subheadline` mono; press: `fillPressed` +
     scale 0.92 (`snap`), key-click haptic.
   - Trailing fixed: joystick (10.3), then `keyboard.chevron.compact.down` (hide keyboard).
2. Composer row (always visible): a one-line glass capsule 48 h (`CmuxMobileComposer` collapsed metrics)
   with `+` (Photos, Camera, Files → uploads to the Mac and inserts the path; Paste image),
   text field "Send to <program>" (autocorrect and smart punctuation off,
   `.keyboardType(.asciiCapable)` optional via setting), mic, primary (send = text + `\r`;
   when empty in TUI mode it sends a bare Return; long press → "Send without Return").
   Expands to multi-line (up to 6) as you type; Return in the field sends.
3. Direct mode: tapping the terminal surface focuses a hidden `UIKeyInput` that sends raw
   keystrokes (vim, TUIs); the composer row then shows a `keyboard` glyph and "Typing into
   terminal" placeholder in `label3`; tap the composer to switch back. Selection mode: long press
   on the surface starts native text selection with the system edit menu (Copy, Paste, Look Up).

Keyboard toggle button (toolbar trailing and key bar trailing): `keyboard` when hidden,
`keyboard.chevron.compact.down` when shown; when hidden, the composer row sits 8 pt above the
bottom safe area and the key bar is hidden.

### 10.3 Joystick

- 36 pt glass circle in the key bar with a 14 pt `label2` dot (thumb). Touch and drag: the
  thumb follows the finger within a 28 pt radius; direction quantized to 4 ways (8 with a
  setting); sends arrow keys while held.
- Gears (Termius): distance from center 8–16 pt = gear 1 (repeat every 160 ms), 16–24 pt =
  gear 2 (80 ms), > 24 pt = gear 3 (30 ms). First key fires immediately on crossing 8 pt.
  `.selection` haptic per key at gears 1–2, every 4th key at gear 3.
- Release: thumb returns with `springBack`.
- Alternative (Termius): long-press-and-slide on the space bar is a system gesture we cannot
  intercept; long press on the terminal surface in direct mode with no selection intent
  (no movement for 300 ms, then movement > 12 pt) acts as a full-screen joystick, with a floating
  glass ring at the touch point.

### 10.4 Customization

Settings > Terminal > Key bar: list of keys with toggles and drag handles; "Reset to default".
Per-program presets later (Claude Code: `⇧tab`, `esc`, `^C`, `/`, `@`).

### 10.5 Comparison checklist (Terminal)

No captured reference. Compare: composer row to `chatgpt-16-working-shimmer` (collapsed
capsule) and `grok-03-composer-typed`; top chrome to `grok-06-scroll-edge-top`; title menu to
`chatgpt-07-codex-title-menu`; key bar against Termius and Blink App Store screenshots (sources).

---

## 11. Workspaces, files and artifacts

### 11.1 Workspaces tab

An inbox ordered by what needs the user (direction A, "Inbox"). Design, research and the
full spec: `verify/workspaces-design-loop.md`. Code: `CmuxMobileWorkspaces/WorkspacesList.swift`
(view) and `WorkspaceInbox.swift` (sections, status, search, folding; unit tested).

- Toolbar: leading drawer, inline title "Workspaces" with a `navigationSubtitle`: the
  filtered Mac and its presence; else "Updating…" when a refresh takes over 1.5 s; else
  "N need you"; else with 2+ Macs "2 of 3 Macs online". Trailing glass capsule: the Mac
  filter (only with 2+ Macs) and New Workspace.
- Mac filter: a toolbar `Menu` of `Toggle`s (a checkmark on the chosen one): All Macs, then
  each Mac (online first, `desktopcomputer`; the model has no Mac kind) titled with its name
  and subtitled with its presence ("Online" / "Last seen 2h ago", plus the link line in live
  mode). Not an inline `Picker`: it drops the subtitles. Filtered fills the symbol
  (`line.3.horizontal.decrease.circle.fill`). Remembered per team
  (`cmuxMobile.workspaces.macFilter.<team>`). In live mode, picking an online Mac the phone is not
  linked to links it.
- New Workspace (`square.and.pencil`): a tap creates one at once on the filtered Mac, else the
  preferred Mac, and pushes it; the row is optimistic (mini spinner) at the top of Recent
  until the Mac confirms. A hold opens the starts the backend supports (agent or browser
  first tab, recent directories, a Mac picker under All Macs only). Disabled while the
  filtered Mac is offline. No Mac: "Connect your Mac" steps.
- Search: `.searchable` in the navigation bar drawer, tucked under the bar at launch,
  revealed by a pull-down. Matches name, branch, directory, Mac name and agent tabs' titles
  and tasks. Results keep the rows; a lone Recent section has no title (as in Mail); offline
  matches show unfolded.
- `List` `.plain` on `bg`, section spacing 4. Section titles are rows that scroll (`meta`
  semibold `label2`, 14 pt above): **Needs You** (only when not empty; newest activity
  first, like Recent and Mail), **Recent** (every other online workspace, newest activity
  first; title omitted when it is the only section), then **one folded line per offline
  Mac** ("`moon.zzz` MacBook Pro · Last seen 2h ago", count, `chevron.right` rotating 90°
  when open) that unfolds its rows in place (`smooth`, per session) and, when the first new
  row would open below the visible area, scrolls it into view (`smooth`, anchor bottom). A
  search or every Mac asleep: always open, no chevron. Filtered to that Mac: no line, only
  its rows (the navigation subtitle says when it was last seen). A workspace on an offline
  Mac never appears in Needs You or Recent. Working and done rows do not jump; only needing
  you moves a row.
- Rows with no known activity time (live: no event since the phone connected) sort after
  every timed row, in the Mac's focus order (`focused_at`), and show no time.
- Workspace row (Mail anatomy): insets 0 / 20, vertical 10. A status gutter centered on
  line 1, 32 pt at Large and scaled like `.body` with Dynamic Type (`UIFontMetrics` from the
  environment's size, as are the discs; `@ScaledMetric` doubled it in list rows):
  `warning` 10 pt disc (needs you), mini spinner (working or creating), 8 pt `label` disc
  (done), else empty. Line 1: the name `rowTitle` semibold (`label3` offline) and a trailing
  `meta` time (`RelativeStamp`, `label` when it needs you). Line 2 `rowSubtitle` `label2`:
  "**Claude is waiting** · <task>", "Codex is working · <task>" (one text, `label2` at rest
  with a `label` highlight sweeping across; static `label2` with Reduce Motion), "**Done** ·
  Claude: <task>", else the branch or directory (the home directory reads "Home"; +
  " · <Mac>" when Recent mixes Macs and no filter is set); offline at 60 % opacity. The
  agent and task come from the tab the state is about (`agentTab(for:)`: the waiting or
  working tab, else the first agent tab); with no agent tab: "Needs you", "Working", "Done".
  Separators start at the text (the gutter). Press: a `fillSelected` row fill while the
  finger is down (not the List cell highlight, which stuck on behind swipe actions). At accessibility
  sizes the name wraps to 2 lines with the time still trailing beside it (no line of its
  own), and line 2 takes 2 lines.
- Status priority: Creating > Offline > Needs you > Working > Done > Idle. Done is the Mac's
  unread flags (`unread_count`, `marked_unread`), cleared on this device when the workspace
  is opened until it has newer activity. Copy says "is waiting": the Mac does not say
  whether it is a permission or a question.
- Tap: a needs-you workspace opens on its waiting tab, which shows the pending permission or
  question card; otherwise the last tab used on this device, else the Mac's active tab
  (`Workspace.activeTabID`), else the first. Offline: no push; an alert "<Mac> is offline"
  with last seen.
- Hold a row: a menu headed "<Mac> · <branch or directory>" ("· Offline"): one item per tab
  (opens that tab; an agent tab is titled with its task, as on the row, with the agent as
  the subtitle), then Rename and Close Workspace (destructive, confirmed), hidden when the
  backend cannot manage the workspace. Offline: the header and "Show <Mac>" (filters).
- Swipe left: Close (system destructive role with `.tint(nil)`) and Rename (`gray`). Close
  is confirmed in a popover pointing at the row (Mail), anchored to a view over the list at
  the row's frame, read from UIKit probe views when Close is tapped (a row's own
  presentation is dropped while its swipe actions close, and SwiftUI geometry inside list
  cells went stale on scroll). At accessibility sizes the popover is nearly screen-tall, so
  the row first scrolls to the top (`smooth`) and the popover opens under it. No
  full swipe, no leading swipe (the team drawer owns it). Rename and close apply at once
  and are undone if the Mac refuses (toast).
- States (live mode reads each Mac's `MacDataMachine` phase): team loading with no cache, or
  the linked Mac dialing with nothing known → `SkeletonList`. Last-known (snapshot) rows show
  at 55 % opacity with no agent state (never "is waiting" from a cache) until the Mac
  answers; while the link connects the subtitle reads "Updating…" after 1.5 s. An online Mac
  whose dial failed with nothing known is a "<Mac> · Can't connect" line (Retry); filtered to
  it, "Can't connect to <Mac>" + Retry. Team failed → "Couldn't load workspaces" + Retry. Filtered online Mac with none → "No workspaces on <Mac>" + New Workspace; filtered
  offline Mac → "<Mac> is offline"; live, filtered to an online Mac the phone is not linked to
  → "<Mac> isn't connected" + Connect; under All, such a Mac is a "<Mac> · Not connected"
  line that links it on a tap. Every Mac asleep → "Your Macs are asleep" header above the
  unfolded offline lines. No results → `ContentUnavailableView.search`.
- Accessibility: one element per row ("cmux, Claude is waiting, Refactor transport layer,
  1 minute ago"), hint "<Mac> is offline" for offline rows, custom actions Rename and Close.
  Section titles are headers; the offline line reports Collapsed / Expanded.
- Workspace screen: the pushed tab (terminal, browser or agent chat) with the
  tab bar hidden; the tab title menu (10.1) switches tabs in place (crossfade `snap`).
- "All tabs" sheet (`.large`): 2-column grid of tab cards (16:10 snapshot thumbnails, radius 16,
  title under), long press to close; `+` card "New tab".

### 11.2 File browser (`CmuxMobileArtifacts`)

- Entry: workspace tab menu "Files", agent chat title menu "Files".
- Toolbar: back, principal = current folder name with `chevron.down` → menu of ancestors
  (breadcrumb), trailing `ellipsis` (Sort, Show hidden files, Copy path).
- Filter field at the top (`.searchable(placement: .navigationBarDrawer)`) filters the current
  folder; global search is the Search tab.
- Rows 56 h: 28 pt type icon (folders `folder.fill` in `label2`, files by type 2.5), name
  `body` (mono for code files is NOT used; names stay SF Pro), `footnote` `label2` "12 KB ·
  Modified 2h ago"; folders get a chevron. Git status badge trailing for changed files (`M` in
  `warning`, `A` `success`, `D` `danger`, `caption` semibold mono).
- Swipe: Share, Copy path. Context menu: Open, Share, Copy path, Open in terminal (cd).

### 11.3 Artifacts

- "Artifacts" view in the workspace menu: what agents produced (screenshots, recordings, reports,
  generated files), as a grid like ChatGPT Library (`chatgpt-26-library-grid`): chip row All /
  Images / Videos / Documents / Code; 2-column grid, 1:1 tiles radius 16, 8 pt gaps, 20 pt
  margins; non-image tiles show a `surface` card with the type glyph 28 and the name
  (`footnote`, 2 lines). Bottom: none (search is the Search tab).

### 11.4 Preview

- Images, PDFs, video: `QLPreviewController` (pinch zoom, share) wrapped with our toolbar.
- Code and text: `CodeView`: line numbers in a 40 pt gutter (`diffGutter` style), `codeBody`,
  wrap toggle in the toolbar menu, syntax colors 2.1, find-in-file (`.findNavigator`), long
  press line → Copy line / Copy permalink.
- Markdown: rendered in `WKWebView` with the Feed stylesheet; toolbar toggle "Source".
- HTML artifacts: `WKWebView` sandboxed (no network unless the file is served by the Mac's
  browser service).
- Large files: stream through the `file` link service with a progress bar under the toolbar
  (2 pt, `label`).

Comparison: `chatgpt-26-library-grid` (grid, chips), `chatgpt-22-uploaded-files-empty` (sheet
empty), `chatgpt-12-codex-search` (search results rows), `chatgpt-38-search-results` (rows with
icon and snippet).

---

## 12. Diff viewer (`CmuxMobileDiff`, GitHub mobile style)

### 12.1 File list

- Toolbar: back, principal "Changes" with `meta` second line "<branch> · 8 files", trailing
  `ellipsis` (Unified / Split, Wrap lines, Hide whitespace, Show viewed files).
- Summary header row: "8 files changed" `headline`, then `+120 −34` in diff colors and a
  5-segment bar (GitHub style: green/red/gray squares, 8 x 8, radius 2).
- File rows 56 h: status letter badge (M/A/D/R, 20 x 20, radius 5, `caption` semibold mono:
  M `warning`, A `success`, D `danger`, R `label2`), file name `body` + directory `footnote`
  `label2` (truncates head), trailing `+12 −4` `meta` mono in diff colors and a viewed toggle
  (`checkmark.circle` / `.fill` in `success`). Tap → file diff.
- Source: whole working tree, a turn's changes (from 6.8), or a PR (future).

### 12.2 File diff

- Sticky file header (pinned under the toolbar, hard edge effect): path (head-truncated mono
  `footnote`), `+/−`, viewed toggle, `ellipsis` (Copy path, Open file, Open in terminal).
- Unified (default on iPhone portrait): rows `codeBody` 13 / line height 20: two gutters (old,
  new) 36 pt each, `diffGutter`, then a 14 pt marker column (`+`, `−`, space), then code.
  Added rows: `diffAddRow` background, gutter `diffAddRow` at double opacity; removed:
  `diffDelRow`; word-level changes `diffAddWord` / `diffDelWord` radius 3.
- Split (iPhone landscape and iPad, or forced): two columns, each with one gutter; horizontal
  scroll is synchronized.
- Hunk header row 32 h: `diffHunkBg`, `@@ -1,11 +1,7 @@ func displayName` in `diffGutter`
  `label2`.
- Collapsed context: unchanged runs > 6 lines collapse to a 32 h row: `arrow.up.and.down`
  + "Expand 24 lines" (`footnote` `label2`) on `diffHunkBg`; tap expands with `smooth`; partial
  expands of 20 lines up/down for long runs (GitHub).
- Wrapping: off by default (horizontal scroll per file, not per line); Settings toggle wraps
  with a hanging indent under the marker.
- Long press a line → menu: Comment (disabled in v1, "Coming soon"; the layout reserves
  `CommentThreadRow` insertion between any two lines), Copy line, Copy with line number, Open
  file at line. Tapping the gutter selects a line range (drag to extend) for future comments
  (GitHub mobile comments on any line, changelog 2026-02-03).
- Bottom glass toolbar (system bottom toolbar): `chevron.up` prev file, `chevron.down` next
  file, `ToolbarSpacer`, "Mark viewed" glass capsule. Viewed files collapse to their header in
  the all-files scroll mode.
- Performance: `UICollectionView` with compositional list layout for diffs > 2,000 lines; text
  laid out with TextKit 2 per row; syntax highlight off the main actor.

### 12.3 Comparison checklist (Diff)

`chatgpt-17-diff-table-stream` (inline diff colors, no row fills; card radius) and
`chatgpt-14-codex-settings` ("Wrap code diff lines" behavior). GitHub Mobile and the web Files
changed page for the file list, hunk and expand rows (sources).

---

## 13. Search tab

`Tab(role: .search)`: the search field sits in the bottom glass bar, focused on entry
(`chatgpt-12-codex-search`, `chatgpt-38-search-results`). Scope chips under the toolbar: All,
Workspaces, Tabs, Feed, Files (`chatgpt-38` has All / Chats / Images / Documents / Projects).
Results: rows 64 h, leading 28 pt icon in a 40 pt `fill` rounded square (radius 10),
title `body` with matched text in semibold, snippet `footnote` `label2` with the match in
`label` semibold (`chatgpt-38-search-results`). Recent searches when the query is empty
(swipe to delete, "Clear" in the section header). Results stream per Mac; per-Mac sections
when more than one Mac answers.

---

## 14. Paywall pattern (documented, not shipped)

Grok `grok-10-paywall`, `grok-09-failure-paywall-card`, `grok-11-sidebar` upgrade banner:
full-height sheet; X circle leading; centered `title2` bold title + `rowSubtitle`; segmented
plan picker (3 segments, 44 h, `fill` track, `fillSelected` thumb); plan card `surface` radius
24 with two price tiles (selected 2 pt stroke + `checkmark.circle.fill`); large white CTA;
feature list with 20 pt line icons and `body` text, 16 pt spacing; footer `caption2` links Terms
· Privacy · Restore Purchases. A colored banner card in the sidebar and in settings ("SuperGrok
Upgrade"). cmux-next-ios ships none of this; if a plan gate is ever needed, reuse `FailureCard` with an
explanatory CTA instead of a sales sheet.

---

## 15. Motion catalog

Every transition in the app. "System" means do not customize.

| Transition | Motion | Notes |
| --- | --- | --- |
| Launch → first screen | Mark scale 1 → 0.92 + fade (`snap`); destination fade in (`gentle`) | 5.1 |
| Welcome intro | One ~5 s choreography: lockup glide, text and buttons in by 0.65 s, illustration drawn, network grows and folds into the chevron | 5.2; crossfade under Reduce Motion |
| Welcome idle | Sync pulse along the network path, chevron beat, every 9 s | 5.2; off under Reduce Motion |
| Onboarding step push | System navigation push | |
| Email code step | System push inside the sheet | |
| Code boxes invalid | `shake` + `.error` | |
| QR corners lock on | Corners move to code bounds, `snappy` | |
| Sidebar open/close | `drawer`, interactive, velocity carried; scrim 0 → 1 linear with progress; sidebar parallax -40 → 0 | 3.3 |
| Team switch | Row highlight `snap`; drawer close `drawer`; content crossfade `gentle` | |
| Tab switch | System (no custom transition) | |
| Tab bar minimize/expand | System | |
| Push to chat / terminal / diff | System push; tab bar hides with the push (system) | |
| Sheets | System (glass at partial height, opaque at full) | |
| Menus, context menus, alerts, confirmation dialogs | System | |
| Composer expand/collapse | Height + corner morph capsule ↔ card, `smooth` | One `glassEffectID` for both shapes |
| Composer primary symbol swap | `.contentTransition(.symbolEffect(.replace))`, `snap` | arrow.up ↔ stop.fill |
| Attachment strip insert/remove | `.transition(.scale(0.8).combined(with: .opacity))`, `snappy` | |
| Send: user bubble appears | Offset y +24 → 0, scale 0.96 → 1, opacity 0 → 1, `snappy` | Starts from the composer's top edge |
| Working shimmer | `shimmer` | |
| Streaming block appears | Opacity 0 → 1, 0.15 s easeOut, new blocks only | No per-word fade |
| Tool row expand/collapse | `smooth`; chevron rotation 0 → 90 degrees | |
| Permission card / question card arrival | Rise 16 pt + fade, `snappy`; composer ↔ action bar crossfade `snap` + height `smooth` | |
| Card resolved → summary row | `smooth` height collapse + crossfade | |
| Plan step check | `.symbolEffect(.bounce)` once | |
| Jump-to-bottom show/hide | Scale 0.85 ↔ 1 + opacity, `snap`; emerges from composer via glass morph | |
| Scroll to bottom | `.smooth(duration: 0.35)` | |
| Copy confirmation | Symbol replace doc.on.doc → checkmark, revert after 1.5 s | |
| Feed "N new" pill | Rise from y - 12 + fade, `snappy` | |
| Feed Show more / less | Row height `smooth` | |
| Feed inline answer submitted | Card → summary, `smooth` | |
| Connection banner | Move from y - 12 + fade, `snappy`; auto-hide after 1.5 s when recovered | |
| Toast | Same as banner; 3 s | |
| Skeleton → content | Crossfade `snap` | |
| Mac presence dot change | Color crossfade `snap` | |
| Terminal disconnect dim | Opacity 1 → 0.6, `gentle` | |
| Key cap press | Scale 0.92 + `fillPressed`, 0.08 s in, `snap` out | |
| Joystick thumb | Follows finger 1:1; release `springBack` | |
| Ctrl lock | Fill `fill` → `fillSelected` → `accent`, `snap` | |
| Diff hunk expand | Inserted rows fade in, height `smooth` | |
| Diff viewed toggle | Symbol replace + file body collapse `smooth` | |
| Settings appearance tiles | Selection stroke `snap`; app appearance change is immediate (no crossfade) | |

---

## 16. Accessibility and quality bars

- Dynamic Type up to AX5 on every screen; toolbars keep 44 pt circles; composer grows; rows
  wrap. Snapshot tests at Large and AX3.
- VoiceOver: every glass circle has a label ("Teams", "Back", "New session", "More"); dots in
  team rows read as "3 of 7 Macs online"; diff rows read "added line 12: …".
- Contrast: text tokens are Apple's; status colors are never the only signal (dots have
  labels in VoiceOver and in the Mac list).
- Hit targets >= 44 x 44 (36 pt circles get 44 pt hit areas via `contentShape`).
- Frame budget: no hitch > 1 frame during streaming, sidebar pan, tab switches or terminal
  scroll on an iPhone 15 (Instruments hitch check per PLAN's verification bar).
- Landscape: chat and terminal support it; the sidebar width stays capped at 360.

---

## 17. Per-screen comparison checklist (verification)

Use with `cmux-next-ios/verify/` (recording, frame split, side-by-side). Compare the same state at
the same device size (iPhone 17 Pro Max, 440 x 956 pt) in dark mode first.

| Screen / state | Compare against | Key checks |
| --- | --- | --- |
| Launch | (none captured) ChatGPT/Claude cold launch from the App Store preview | Mark only, no spinner |
| Welcome + sign-in buttons | Mobbin ChatGPT welcome/login screens (sources) | Button order Apple first, 52 h pills, footer legal |
| Email code | `chatgpt-09-codex-pair-manual` (boxes) | Box size, disabled CTA |
| Setup: pair Mac | `chatgpt-10-codex-setup-onboarding`, `chatgpt-05-codex-pair-intro` | Glyph, rows, two CTAs |
| QR scanner | `chatgpt-08-codex-qr-scan` | Viewport radius, yellow corners, outline CTA |
| Manual pairing sheet | `chatgpt-09-codex-pair-manual` | 4+4 boxes, dash, disabled Pair |
| Home (Chief) empty | `grok-01-home-keyboard`, `claude-05-composer-focused`, `chatgpt-01-new-chat` | Composer card, centered empty glyph |
| Home with transcript | `claude-09-chat` | Bubble, prose, action row |
| Team sidebar | `chatgpt-03-sidebar`, `claude-01-sidebar`, `chatgpt-23-sidebar-selected-expanded`, `chatgpt-32-sidebar-explore-expanded` | Width 75%, card radius, selected row fill, bottom capsule + circle |
| Team row context menu | `grok-15-row-context-menu` | Destructive red last |
| Team appearance sheet | `chatgpt-29-new-project-sheet` | Emoji field, docked CTA |
| Workspaces list | `chatgpt-30-scheduled` (density), `claude-02-code-empty` (Devices + Sessions sections) | Section headers, row rhythm |
| Workspaces empty / no Macs | `chatgpt-11-codex-connect-empty`, `claude-02-code-empty` | Empty layout |
| Workspaces load error | `chatgpt-06-codex-error-state` | Cloud glyph, Retry capsule |
| Workspace title menu | `chatgpt-07-codex-title-menu` | Sections, checkmark |
| Add Mac sheet (remote control) | `claude-03-add-device-sheet` | Sheet header, command chip |
| Agent chat (all states) | Section 6.10 | |
| Feed | Section 8.3 | |
| Settings root and bottom | Section 9 | |
| Terminal | Section 10.5 | |
| Files / artifacts | `chatgpt-26-library-grid`, `chatgpt-27-library-folders-empty`, `chatgpt-38-search-results` | Chips, grid gaps |
| Diff viewer | Section 12.3 | |
| Search tab | `chatgpt-12-codex-search`, `chatgpt-38-search-results` | Field placement, scope chips, match bolding |
| Offline banner, toast | (none) | Capsule under toolbar, one at a time |
| Inline failure card | `grok-09-failure-paywall-card` | Stroke card, white CTA |
| Alert | `claude-04-new-session-alert` | System alert |
| Sheet with photos (attachments) | `claude-06-add-context-sheet` (not adopted; menu chosen) | |
| Scroll edge under chrome | `grok-06-scroll-edge-top` | Soft fade, no hard divider |
| Temporary/ephemeral states (none) | `chatgpt-37-temporary-chat` | n/a |
| Model/effort | `chatgpt-33-effort-slider`, `chatgpt-34-effort-slider-medium`, `chatgpt-35-configure-sheet`, `chatgpt-36-chat-mode` | Menu chosen over slider; check pill text |

---

## 18. Open decisions (need an owner)

- Assistant prose font: SF Pro chosen; a serif option (Claude) could be an Appearance setting.
- Feed body renderer: PLAN says `WKWebView`; if scroll hitches exceed budget, switch to native
  `AttributedString` markdown with code cards and keep WebView only for tables and HTML.
- Whether Settings stays a tab or becomes a sheet from the sidebar avatar (ChatGPT, Claude,
  Grok all use a sheet). The brief fixes it as a tab for v1.
- Live Activity and notification visuals need their own spec (Cursor and Moshi ship both).

---

## Sources

Apple
- WWDC25 "Meet Liquid Glass": https://developer.apple.com/videos/play/wwdc2025/356/
- WWDC25 "Build a SwiftUI app with the new design": https://developer.apple.com/videos/play/wwdc2025/323/ (notes: https://wwdcnotes.com/documentation/wwdc25-323-build-a-swiftui-app-with-the-new-design/)
- WWDC25 "Build a UIKit app with the new design": https://developer.apple.com/videos/play/wwdc2025/284/
- WWDC23 "Animate with springs" notes: https://wwdcnotes.com/documentation/wwdc23-10158-animate-with-springs/
- HIG, Sign in with Apple buttons: https://developers.apple.com/design/human-interface-guidelines/technologies/sign-in-with-apple/buttons
- `ASAuthorizationAppleIDButton.cornerRadius`: https://developer.apple.com/documentation/AuthenticationServices/ASAuthorizationAppleIDButton/cornerRadius
- HIG tab bars change log mirror (v27 vs v26): https://appguidelines.com/human-interface-guidelines/version/27/tab-bars/

iOS 26 APIs (community)
- Donny Wals, tab bars on iOS 26: https://www.donnywals.com/exploring-tab-bars-on-ios-26-with-liquid-glass/
- Hacking with Swift, minimize TabView on scroll: https://www.hackingwithswift.com/quick-start/swiftui/how-to-make-a-tabview-minimize-on-scroll
- Hacking with Swift, TabView accessory: https://www.hackingwithswift.com/quick-start/swiftui/how-to-add-a-tabview-accessory
- Swift with Majid, glassifying tabs: https://swiftwithmajid.com/2025/06/24/glassifying-tabs-in-swiftui/
- Create with Swift, collapsing tab bar: https://www.createwithswift.com/making-the-tab-bar-collapse-while-scrolling/
- Liquid Glass glassEffect and glass buttons: https://jorgemrht.dev/2025/09/17/liquid-glass-glassEffect-buttons
- GlassEffectContainer: https://dev.to/arshtechpro/understanding-glasseffectcontainer-in-ios-26-2n8p
- Liquid Glass reference: https://medium.com/@madebyluddy/overview-37b3685227aa
- iOS 26 sheets in Expo (detent glass behavior): https://expo.dev/blog/how-to-create-apple-maps-style-liquid-glass-sheets
- react-native-screens sheet `backgroundEffect` issue: https://github.com/software-mansion/react-native-screens/issues/4605
- learnui.design iOS 26 patterns: https://www.learnui.design/blog/ios-design-guidelines-templates.html
- SwiftUI animation timing: https://nilcoalescing.com/blog/AnimationTimingInSwiftUI/
- Spring parameter guide: https://github.com/GetStream/swiftui-spring-animations

AI apps
- ChatGPT iOS on Mobbin (welcome, login, chat): https://mobbin.com/explore/screens/52bab164-8fc0-4def-be5b-e7153f3dd49a , https://mobbin.com/explore/screens/96f667da-a321-4130-ae70-7d8ec83a9bb7 , https://mobbin.com/explore/screens/f7e6514e-4106-4b5a-8c37-1b86aa42a9f1
- ChatGPT screens on Banani: https://www.banani.co/references/apps/chatgpt
- ChatGPT iOS FAQ (haptics setting): https://help.openai.com/en/articles/7885016-chatgpt-ios-app-faq
- ChatGPT Liquid Glass update note: https://www.threads.com/@testingcatalog/post/DO6rriwjZor/chatgpt-app-for-ios-now-follows-liquid-glass-style-on-ios-26-in-the-latest-updat
- ChatGPT desktop streaming fade parameters (Echora PR): https://github.com/rita152/Echora/pull/14
- Streaming fade removed for performance (Hermex): https://github.com/uzairansaruzi/hermex/issues/1125 , https://github.com/uzairansaruzi/hermex/issues/1121
- Shimmering "Thinking" label: https://margelo.com/blog/building-native-llm-chat-app-with-rag
- Claude Code on mobile docs: https://code.claude.com/docs/en/mobile
- Claude Code Remote Control: https://simonwillison.net/2026/Feb/25/claude-code-remote-control/ , https://claudefa.st/blog/guide/development/remote-control-guide , https://pasqualepillitteri.it/en/news/12249/claude-code-start-session-from-phone
- Grok app reviews: https://nubiapage.com/app-website-login-imagine-chatbot-experience/ , https://macdailynews.com/2026/08/29/how-to-use-grok-ai-on-your-mac-iphone-and-ipad/
- T3 Code iOS (App Store): https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824
- T3 Code repo: https://github.com/pingdotgg/t3code ; streaming haptics issue: https://github.com/pingdotgg/t3code/issues/13116
- T3 Code mobile overview: https://continuumcode.ai/guides/t3-code-mobile-app/
- Cursor for iOS: https://cursor.com/blog/ios-mobile-app , https://cursor.com/changelog/ios-mobile-app , https://thenextweb.com/news/cursor-mobile-app-coding-agents-phone
- Perplexity iOS: https://www.perplexity.ai/changelog/what-we-shipped-september-5th , https://aiuxplayground.com/teardowns/perplexity/output/ , https://www.banani.co/references/apps/perplexity

Terminals
- Termius touch terminal (gesture arrows, gears, add-on): https://termius.com/blog/new-touch-terminal-on-ios
- Termius mobile terminal docs: https://docs.termius.com/terminal/mobile-terminal ; changelog: https://docs.termius.com/changelog/ios
- Blink Shell smart keys: https://docs.blink.sh/
- Moshi, iOS terminals for coding agents: https://getmoshi.app/articles/best-ios-terminal-app-coding-agent , https://getmoshi.app/articles/blink-vs-termius
- La Terminal: https://la-terminal.net/ , https://apps.apple.com/us/app/la-terminal-mosh-ssh-client/id1629902861

Diffs
- GitHub Mobile, comment on unchanged lines: https://github.blog/changelog/2026-02-03-github-mobile-comment-on-unchanged-lines-in-pull-request-files/
- GitHub Files changed redesign: https://github.blog/changelog/2025-06-26-improved-pull-request-files-changed-experience-now-in-public-preview/
- GitHub docs, reviewing changes: https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/reviewing-proposed-changes-in-a-pull-request
- GitHub Mobile tips (split/unified, long-press comments): https://github.com/orgs/community/discussions/168685
- iPhone diff review reference implementation: https://github.com/bailycase/shepherd/pull/38

cmux-next
- Token derivation and the neutral accent: `plans/cmux-next/spec-proposals/visuals/design-tokens.md`, `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Palette.swift`
- Reference captures: `~/Downloads/cmux-native-references/REFERENCES.md` (outside the repo)
