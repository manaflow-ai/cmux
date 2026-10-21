# CmuxConversation requests from the Home and Chief design pass

For the `feat-imsg-parity-gui` owner. From the designer's review in
[SPEC.md](SPEC.md) (2026-10-14), items U1 to U6, plus one request (U7)
that came up while implementing the mobile side.

cmux-next-ios does not fork the package. `Packages/iOS/CmuxConversation` stays
byte-identical to `origin/feat-imsg-parity-gui`, and
`cmux-next-ios/scripts/check-tabskit-sync.sh` checks this. Every request below keeps
today's behavior as the default, so the Messages lab host and the Mac Home
are unchanged unless a host opts in.

Image paths are relative to this file.

| # | Request | Default (Messages) | Chief passes | Spec |
| --- | --- | --- | --- | --- |
| U1 | `serviceSymbol` on the service line | `"lock.fill"` | `nil` | 3.3 |
| U2 | Markdown in incoming text | off | on | 3.2 |
| U3 | Backdrop blur behind the "+" menu (Camera is already there on devices) | blur on | blur on | 3.4 |
| U4 | Keyboard rising from a scrolled-up transcript: measure against Messages | n/a | n/a | 3.5 |
| U5 | New Message: suggestions with an empty "To:", and a contact `subtitle` | off, handle | not used now | 5 |
| U6 | A host hook that replaces the contact details | package details | `ChiefSettingsView` | 4 |
| U7 | A public call to focus the composer | n/a | Home's compose | 1.4 |

---

## U1. The service line's lock (Major)

**Seen:** `img/03-chief-transcript-dark-light.png`, left. The transcript's
start header reads "Chief / 🔒 Runs your agents on your Macs". The lock is
Messages' "Encrypted" glyph. Next to Chief's subtitle it claims encryption that
the sentence does not.

**Code today:** `ConversationCells.swift`, `text(title:subtitle:color:)`,
always appends a `lock.fill` attachment before the subtitle.
`ConversationComposeViewController.swift:106` draws the same lock in New
Message.

**Proposal:**

```swift
public struct ConversationPresentationOptions {
    // ...existing fields...
    /// SF Symbol drawn before `serviceSubtitle` in the transcript's start
    /// header (and New Message's service line). nil draws the subtitle alone.
    public var serviceSymbol: String?   // default "lock.fill"

    public init(placeholder: String? = nil, serviceTitle: String = "iMessage",
                serviceSubtitle: String? = nil, unreadCount: Int = 0,
                trailingSymbol: String = "video",
                serviceSymbol: String? = "lock.fill")
}
```

- **Default:** `"lock.fill"`, drawn exactly as today (9.33 pt, on the baseline).
- **Chief passes:** `nil`, which gives "Chief / Runs your agents on your Macs".
- **Layout:** with no symbol, the subtitle's line height must not change, so the
  header's measured height (`text(...).boundingRect`) stays the same.

## U2. Markdown in incoming text (Major)

**Seen:** `img/03-chief-transcript-dark-light.png`, right. Chief's turn
"Heads up: Claude in cmux is asking to run \`cargo test -p cmux-mobile-link\`. Want me
to allow it?" shows the backticks. Chief writes every turn in Markdown.

**Why the host cannot do it:** `ConversationMessage.text` is plain text. If the
host strips the Markdown and passes `ConversationTextRun`s for bold and italic,
Copy, Reply quotes, and Translate get altered text. There is also no run kind
for inline code or a code block. mobile does not rewrite the message text.

**Proposal:** one of these. The first is preferred.

1. A host flag, with the parsing in the package:

   ```swift
   public struct ConversationPresentationOptions {
       /// Renders incoming (not my) message text as Markdown: inline code,
       /// **bold**, *italic*, links, "-" and "1." lists, and fenced code
       /// blocks. The message's text stays the source: Copy, Reply's quote
       /// and Translate use it.
       public var rendersIncomingMarkdown: Bool   // default false
   }
   ```

2. A `code` kind in `ConversationRichText`: `ConversationTextStyle.code`, and a
   block form for fenced code. The host would supply runs without rewriting the
   text, so it could keep the markers.

**Precedence with host runs:** when a message has `ConversationTextRun`s
(bold, italic, effects from the sender's composer) and the flag is on, the
host's runs win. Markdown is parsed only for a message with no runs, and an
incoming message with runs renders as it does today. The two never merge:
Chief's turns carry no runs, and a person's styled text is never re-read as
Markdown. Under option 2 there is nothing to combine, because the host
supplies every run itself.

**Rendering (from SPEC 3.2):**

- Inline code is SF Mono at the bubble's size minus 1 pt, on the bubble's own
  color.
- A fenced block is a monospaced paragraph inside the bubble. It scrolls
  horizontally only when it is wider than the bubble.
- **Bold**, *italic*, links, and `-`/`1.` lists use the bubble font.
- Outgoing text stays plain, as in Messages.

**Default:** off. Messages never renders Markdown.

## U3. "+" menu: backdrop blur (Polish)

**Seen:** `img/04-plus-menu-and-long-press.png`. The menu lists Photos and Files.
The transcript behind it stays sharp at full brightness.

**Correction to SPEC 3.4:** Camera is already in the package.
`ConversationViewController+Apps.swift` adds Camera first when
`UIImagePickerController.isSourceTypeAvailable(.camera)`. The simulator has no
camera, so the designer's capture lacks it. Check Camera on a device; no
request is needed for it.

**Still requested:** Messages iOS 26 blurs and dims the transcript and composer
behind the menu.

- **Blur:** `systemUltraThinMaterial` strength, with the content dimmed to 70%.
- **Motion:** the blur animates in with the menu's spring and out with its
  dismissal.
- **Default:** on. This is Messages parity, so no option is needed. This
  deliberately changes every host, including the Messages lab host and the
  Mac Home, which get the blur too; that is the point (both compare
  against Messages). A host that must keep the sharp backdrop would need an
  opt-out, and none is asking for one.

## U4. Keyboard from a scrolled-up transcript (Polish, verify first)

**Seen:** `img/06-keyboard-scrolled-up-r1-sheet.png`. With the transcript at its
top, tapping the field raises the keyboard. The composer then covers the rows
that were just above it, and the content offset does not change.

**Ask:** measure Messages on a device, scrolled up the same way.

- If Messages keeps the row that was above the composer visible (the content
  shifts up by the keyboard height), match it.
- If it does not, keep the current behavior.

No API is needed. mobile changes nothing for this.

## U5. New Message: empty "To:" suggestions and contact subtitles

**Status for mobile:** the user decided on 2026-10-14 that Home's compose button
opens the Chief conversation. Home no longer shows New Message. Chief's select
mode still uses New Message for Forward, so these remain useful. They are
low priority.

**Seen:** `img/10-new-message.png`.

- The sheet is blank until a letter is typed.
- Each suggestion prints the handle's label and then its value: "Chief Runs your
  agents", "Claude cmux".

**Proposal:**

```swift
public struct ConversationContact {
    // ...existing fields...
    /// The suggestion row's second line. nil prints the handle (label, then value) as today.
    public var subtitle: String?
}

// ConversationComposeViewController
public var showsSuggestionsWhenEmpty: Bool   // default false
```

- **Defaults:** `subtitle: nil` and `showsSuggestionsWhenEmpty: false`, which is
  today's behavior.
- **Chief would pass:** the subtitle "Runs your agents on your Macs", and
  "Claude on <Mac name>" for agents, with suggestions on (Chief first).
- **Also:** New Message's field has no placeholder. Messages shows "Message"
  there; use that as the default.

## U6. A hook that replaces the contact details (Major, filed before)

This is the same request as item 6 of `verify/imsg-upstream-requests.md`. It is
repeated here because the mobile workaround is fragile.

`ChiefConversationContainer.takeOverHeader` finds the header's avatar, name,
and trailing buttons by accessibility id (`conversation.header.name`,
`conversation.header.trailing`, and the one header button with a hint). It then
retargets them to Chief's settings. If those ids change, Chief silently shows
the package's Call/FaceTime/Mail details again.

**Proposal:**

```swift
// ConversationViewController
/// Called instead of presenting the package's contact details (avatar,
/// name pill, and the trailing button in its plain state). nil keeps the
/// package's details.
public var onShowDetails: (() -> Void)?
/// The trailing button's VoiceOver label in its plain state. nil keeps
/// the package's own label for the symbol ("Call" for "video").
public var trailingAccessibilityLabel: String?
```

- **Defaults:** both `nil`. `onShowDetails: nil` shows the package's
  details; `trailingAccessibilityLabel: nil` keeps the package's label.
- **Chief passes:** a closure that presents `ChiefSettingsView`.

## U7. Focus the composer from the host (new)

**Need:** Home's compose button now pushes the Chief conversation with the
keyboard up (SPEC 1.4). The keyboard should rise once the push settles, in
the same turn as `viewDidAppear`, with no delay.

**Code today:** `focusComposerIfEmpty()` is internal and only runs for an empty
conversation. mobile finds the composer's text view by its accessibility id,
`conversation.composer.text`, and calls `becomeFirstResponder()` on it
(`ChiefConversationContainer.focusComposer`). That uses only UIKit API. If the
id changes, the screen opens without the keyboard, but nothing else breaks.

**Proposal:**

```swift
// ConversationViewController
/// Makes the composer first responder (keyboard up), keeping its draft.
/// Safe to call before the view is in a window: it runs once it is.
public func focusComposer()
```

**Default:** n/a, because it is only called by a host.

## U8. Host rows under the header that push the transcript down (new, round 3)

**Need:** Chief shows a pinned row while it asks a question ("Chief is
asking · Answer"), as Messages pins a business chat's request or "Report
Junk" under its navigation bar. Messages' pinned rows push the transcript
down; they never cover a bubble (round 2 review, R2-1).

**Code today:** `ConversationViewController.updateInsets()` sets the
transcript's top inset to `header.frame.maxY + 3.33`, and the header is
pinned to `view.safeAreaLayoutGuide.topAnchor`. A host's
`additionalSafeAreaInsets.top` therefore moves the header and the transcript
together. A row placed under the header still covers the transcript.

**Workaround in mobile (no package change):** the conversation gets
`additionalSafeAreaInsets.top = bar height + 8`, and the bar sits in that
room above the header (`ChiefConversationContainer.layoutQuestionBar`). No
bubble is ever under it, but the bar is above the avatar instead of under
the name pill.

**Proposal:**

```swift
// ConversationViewController
/// A host view pinned under the header, full width. The transcript's top
/// inset grows by its height (plus 8 pt), animated with it, so no row is
/// ever under it; nil removes it.
public func setHeaderAccessory(_ view: UIView?, animated: Bool)
```

- **Default:** no accessory, so the layout is unchanged.
- **Chief passes:** the question bar.
- **When it lands, mobile removes:** the `additionalSafeAreaInsets.top` room and
  the solid top band behind the status bar and the bar
  (`ChiefConversationContainer.topBand`, round 3 review R3-1). The band exists
  only because the bar sits above the header; under the header, the
  package's own header wash covers it.
