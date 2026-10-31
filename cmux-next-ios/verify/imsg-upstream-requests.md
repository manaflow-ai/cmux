# Proposed CmuxConversation changes for the iMessage team

cmux-next-ios uses `Packages/iOS/CmuxConversation` exactly as
`origin/feat-imsg-parity-gui` ships it (c4741ca97f05 when this was written). We do not
patch the package. These are the changes Chief would need from it. They are proposals
only and have not been pushed to any `feat-imsg-*` branch.

## 1. Incoming rows follow the send-time drawer in a one-to-one conversation

- **Need:** in Chief, the user wants every bubble to slide left when the transcript is
  swiped to show send times. Earlier feedback said "only the blue ones moved".
- **Package today:** `TimestampDrawerRows.travel(isOutgoing:inAvatarTranscript:reveal:)`
  moves incoming rows only in a group, where they sit in an avatar column. In a 1:1
  transcript they stay still. The package measured this on a real iPhone, and it is
  what Messages does. The side-by-side runs show the same behavior in the lab host and
  in Chief (`evidence/2026-10-13/imsg/*/06-timestamps-held-sbs.png`).
- **Smallest additive option:** a `ConversationPresentationOptions` flag with a default
  of `false`, so current behavior does not change. `MessageCell` and `TypingCell` pass it
  into `inAvatarTranscript`:

  ```swift
  // ConversationPresentationOptions
  public var incomingRowsFollowTimestampDrawer: Bool   // init default false
  // MessageCell.applyShifts / TypingCell.applyTimestampDrawerOffset
  inAvatarTranscript: model.reservesAvatarColumn || incomingFollowsTimestampDrawer
  // ConversationViewController cellForItemAt (message and typing cells)
  cell.incomingFollowsTimestampDrawer = options.incomingRowsFollowTimestampDrawer
  ```

  cmux-next-ios carried this patch until 92f8e689e693. It is in the history of
  `feat-cnx-ios-imsg` (`git show f7eb555f24e7 -- Packages/iOS/CmuxConversation`).
- **Until the package has it:** Chief keeps Messages' behavior. Outgoing rows slide and
  incoming rows stay still.

## 2. Replace the service line in New Message

- **Need:** Chief must not show "iMessage" or "Encrypted". `ConversationPresentationOptions`
  already replaces both in a conversation's start header (`serviceTitle`,
  `serviceSubtitle`). New Message (`ConversationComposeViewController`) has no such
  option.
- **Package today:** the line under the To: field shows "iMessage" whenever every
  resolved recipient's service is `.iMessage`. A `ConversationContact`'s service is
  `.iMessage` or `.sms` and is never nil, so a contact always resolves to one of the
  two. Chief's directory now returns plain contacts. Picking Chief or an agent
  therefore shows "iMessage" and the encrypted line in the sheet.
- **Smallest additive option:**
  `public var serviceLine: (title: String, subtitle: String)?` on
  `ConversationComposeViewController`. When it is set, it replaces the iMessage line.
  The SMS line keeps Messages' wording. cmux-next-ios carried this patch until 92f8e689e693.

## 3. Observations that are the package's own behavior (not Chief's)

These reproduce the same way in the lab host built from `origin/feat-imsg-parity-gui`
and in Chief, on iOS 26.5 and iOS 27.0. We list them so the iMessage team can confirm
they are intended. Chief will not work around them.

- **Rows behind the header.**
  - iOS 26: the header backdrop is a measured color wash, with a peak opacity of 0.60 in
    dark mode (`ConversationTopEdgeGeometry`). Rows stay readable behind the back button,
    avatar and name. That is the "bleed" in the user's screenshot.
  - iOS 27: rows are blurred (UIKit's soft edge effect) instead.
  - Both hosts look identical (`01-open`, `02-under-header`).
- **Tapback badges near the header.** A tapback badge scrolls under the header the same
  way in both hosts (`10-heart-under-header`).
- **Composer input in the lab host (intermittent).** In two runs the lab host's composer
  dropped synthesized typing after Reply or after a tap on the field, while Chief's
  composer, running the same package code, took it every time. We did not find the cause.
  It may be the lab app's window or focus handling, or the harness.

## 4. The cmux iOS app crashes at launch on iOS 26.5 when built with Xcode 27

- **What happens:** a Debug simulator build of `ios/cmux.xcworkspace` (scheme `cmux-ios`) from
  `origin/feat-imsg-parity-gui`, built with Xcode 27.0 (27A266a), is killed by dyld at launch on
  the iOS 26.5 runtime. The log says `Symbol not found: _swift_initBorrow`, referenced from
  `cmux.debug.dylib`. The symbol comes from swift-collections' `InternalCollectionsUtilities`.
  The same build runs on iOS 27.0.
- **Also:** `MobilePinnedNavigationBar.swift` calls `.toolbarMinimizeBehavior(.never, for:
  .navigationBar)`. That API does not exist in the Xcode 27.0 SDK, so the file does not
  compile. We removed that line in our scratch checkout only.
- **How we worked around it:** on iOS 26 the reference was their `ConversationLabView.swift`,
  copied unchanged into a scratch app (see [imsg-parity.md](imsg-parity.md)).

## 5. The trailing header button's VoiceOver label for a custom symbol

- **Need:** Chief passes `trailingSymbol: "clock.arrow.circlepath"` for its history button.
- **Package today:** `ConversationHeaderView` labels the button "FaceTime" for a `video*`
  symbol and "Call" for any other symbol, so VoiceOver reads Chief's history button as "Call".
- **Smallest additive option:**
  `ConversationPresentationOptions.trailingAccessibilityLabel: String?`, with a default of nil
  that keeps the current labels.

## 6. Details: a host hook, or options for the quick actions and switches (Chief)

- **Need:** Chief's details must not show controls that do nothing. User feedback on
  the details page: "these toggles don't do anything, they're useless", and the
  switches "don't have the animation".
- **Package today:**
  - `ConversationViewController.openInfo()` always presents
    `ConversationDetailsViewController`.
  - `ConversationDetailsHeaderView` always adds Call, FaceTime and Mail, disabled.
  - `ConversationDetailsInfoPage` always shows Hide Alerts, plus Send Read Receipts
    in a direct chat.
  - Each switch calls `store.updateListState`. The store notifies `.listState`
    synchronously, and the page answers with `table.reloadData()`. That rebuilds the
    cell and replaces the `UISwitch` in the middle of its own tap, so the switch
    jumps to its new value instead of sliding. When the backend rejects the change,
    a second reload jumps it back.
  - None of these types or members are public.
- **What Chief does meanwhile (host only):** `ChiefConversationContainer` finds the
  header's name button (`conversation.header.name`), its avatar tap button (the custom
  button with a hint) and its trailing button (`conversation.header.trailing`). It
  replaces their `touchUpInside` actions so they open a host sheet,
  `ChiefSettingsView`, with native toggles. The trailing button also keeps the
  package's own action for reply, edit and select modes. If a later package renames
  these markers, its own details come back.
- **Smallest additive options, any one of them:**
  - `ConversationViewController.onShowDetails: (() -> Void)?`: when set, the
    header's avatar and name call it instead of `openInfo()`.
  - `ConversationPresentationOptions.detailsQuickActions: [Action]` (default: Call,
    FaceTime, Mail) and `detailsShowsReadReceipts: Bool` (default true).
  - Separately from the hook: in `ConversationDetailsInfoPage.storeDidChange`, skip
    `reloadData()` for `.listState` when the visible switches already show the new
    state, or update the switches in place with `setOn(_:animated: true)`. Upstream
    fixed this part in 35dc5dd0 ("details switches slide like system switches"),
    synced here. The hook and the quick-action options are still needed.

## 7. The trailing header button's label and its mode (Chief)

- Extends item 5. Chief now uses `trailingSymbol: "slider.horizontal.3"` for its
  settings.
- **Problem:** the host cannot tell whether the button is in its action state or
  shows the xmark of reply, edit or select mode. `trailingMode` is internal, so Chief
  reads the button's image description.
- **Smallest additive option:** a public `onHeaderAction: (() -> Void)?`, called only
  in the action state, plus item 5's `trailingAccessibilityLabel`.

## 8. A Try Again action on an incoming message that reports a failure (Chief)

- **Need:** when Chief's turn fails because its model server is down, the
  Mac's brain posts an ordinary Chief text message ending in
  `(turn failed on claude: <error>)` and does not run that turn again by
  itself. The phone rewrites the note to a plain sentence and offers Try
  Again. In Messages terms the action belongs on that bubble, the way
  Not Delivered puts Try Again under an outgoing one.
- **Package today:** the Not Delivered footer and its Try Again exist only
  for outgoing messages (`ConversationCells.swift` `.notDelivered`). An
  incoming message has no footer action, and the host cannot add one.
- **What cmux-next-ios does meanwhile:** the bar under the header (the one used
  for Chief's questions) shows "Chief couldn't reach its model … Try
  Again" while the failed message is the newest. It goes once a newer
  message arrives (`ChiefQuestionBar`, `ChiefSession.barItem`).
- **Smallest additive option:** an optional per-message footer action that
  a host sets, drawn like Not Delivered under an incoming bubble:

  ```swift
  // ConversationMessage
  public var footerAction: ConversationFooterAction?   // default nil
  public struct ConversationFooterAction: Hashable, Sendable {
      public var status: String     // "Not finished"
      public var title: String      // "Try Again"
      public var id: String         // handed back to the host
  }
  // ConversationViewController
  public var onFooterAction: ((_ messageID: String, _ actionID: String) -> Void)?
  ```
