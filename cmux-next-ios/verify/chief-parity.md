# Chief: parity with the iMessage GUI host

Branch `feat-cnx-ios-chief`, 2026-10-13. This round fixes user feedback on
the Chief chat and Home. It merges `origin/feat-imsg-integration` round 13
(83674d4b30cc); that merge changed only `Packages/iOS/CmuxConversation`. The
evidence is in `verify/evidence/2026-10-13/chief/` and is git-ignored.

## How Chief hosts the iMessage GUI

Chief uses CmuxConversation's `ConversationViewController` as is, over a
`ConversationStore` and a `ConversationBackend`. The other team's lab host,
`ConversationLabView` on their branch, does the same. Our host differs from
the lab in these ways:

| | Lab host | Chief | Behavior change |
| --- | --- | --- | --- |
| Container | `UINavigationController` with the bar hidden, the conversation as root | Pushed on Home's SwiftUI `NavigationStack` with the bar hidden. A container controller restores the edge swipe. | None. Back pops, and the edge swipe works (see below). |
| Store | Created with the controller | Shared with Home's list through `ChiefSession`, and already connected when the screen opens | Yes: the empty header (fixed in the package, see 2) |
| Conversation kind | **group** by default (`conversation=direct` is opt-in) | direct (you and Chief) | Yes: the send-time drawer (see 1) |
| `meID` and participants | Come from the simulator | `user_local` and `agent_chief`, with names and initials | None |
| Back | Opens New Message (the lab has no list) | Pops to Home | Intended |
| Forward (select mode) | New Message with the draft | New Message with the draft (`ChiefComposer`) | None |
| Back unread count | Unread in the other conversation | 0 | Small. Home has no unread model for agent chats yet. |
| Service line | "iMessage / Encrypted" | "Chief / Runs your agents on your Macs" | Text only |

## Fixes

1. **Only the blue bubbles moved left.** CmuxConversation follows the
   Messages behavior it measured with `TimestampDrawerRows`: in a direct
   chat, incoming rows stay still; in a group, every row slides. The lab's
   default conversation is a group, so every row slides there. Chief is a
   direct chat. A new package option,
   `ConversationPresentationOptions.incomingRowsFollowTimestampDrawer`, is off
   by default, so the package's behavior is unchanged. Chief turns it on, so
   incoming bubbles, their tapbacks and the typing bubble slide with the
   outgoing ones, as in the lab.
2. **The header was often empty, with a stray white dot.** The controller
   configured its header only on a `.connection` change, or on a rebuild
   once the header was in a window. Chief's store is shared and already
   connected, and the first rebuild runs in `viewDidLoad`, before the header
   is in a window. So the header stayed blank until the next message
   arrived. The white dot was the unread pill, which shows by default with
   no count. The fix is in the package: `configureHeaderIfNeeded()` also runs
   in `viewIsAppearing`, and the unread pill starts hidden.
3. **Photos came back "Not Delivered".** `ChiefMockBackend.uploadImage`
   threw an error. The mock now stores the uploaded bytes (and files), and
   `send` attaches them to the message. Chief answers a photo. For
   `ChiefDaemonBackend`, `conversation-attachment-upload` uploads by SHA-256
   (begin, then 2 MiB chunks to stay under the link's 4 MiB line cap, then
   commit), and `message.send` names the hash in an `attachment` part.
   Incoming attachment parts are read once with
   `conversation-attachment-read`, so the bubble can render from the bytes.
4. **Compose opened the existing Chief chat.** That was not intended.
   Compose now opens Messages' New Message sheet: CmuxConversation's
   `ConversationComposeViewController` over a `ChiefDirectory`. The
   directory lists Chief first, then each agent tab of the active workspaces
   (for example "Claude · cmux"). Text that matches no recipient becomes a
   red token. The first send routes like this:
   - Chief alone: pushes the Chief chat and sends the message there.
   - One agent: pushes that agent's chat and sends the message as its
     prompt.
   - Several recipients: pushes Chief with "To A, B: …", so Chief routes it.

   The sheet's service line reads "cmux / Chief and your agents, on your
   Macs". It uses a new `serviceLine` property on the compose controller,
   which defaults to Messages' wording.
5. **Navigation.** Chief is pushed on Home's stack and has the header's back
   button. SwiftUI disables the edge swipe while the bar is hidden.
   `ChiefConversationContainer` turns the edge swipe back on while Chief is
   up and makes the transcript's pans (reply swipe, drawer) wait for it. It
   hands the recognizer back to UIKit when Chief leaves.
6. **The Photos button crashed.** The Info.plist had no
   `NSPhotoLibraryUsageDescription`, and the Photos drawer calls
   `PHPhotoLibrary.requestAuthorization`. The crash reproduced with that key
   removed from the built app: `OS_REASON_TCC`, see
   `photos-crash-without-key-ios26.log`. `project.yml` now declares the key,
   and also `NSMicrophoneUsageDescription`, which the composer's audio
   recording needs. This is an app-wide fix, so it also covers the agent and
   terminal composers.
7. **Home has no visible "Conversations" title.** The title stays for
   VoiceOver (`.toolbar(removing: .title)`, inline mode). The search row and
   Chief's pin now sit right under the toolbar, with no gap.

## Verification

- Simulators `cmux-mobile-chf-ios26` (iOS 26.5) and `cmux-mobile-chf-ios27` (iOS 27.0),
  iPhone 17 Pro, dark mode, `CMUX_MOBILE_MOCK_AUTH=1`, headless (Simulator.app was
  never opened).
- `verify/record-chief-parity.sh <udid> <label>` records
  `-cmux-mobile-demo chief-parity`. The run covers:
  1. Home, with no title.
  2. New Message to "claude": the agent chat opens and the prompt runs.
     Back to Home.
  3. New Message to "chief": the Chief chat opens with its header filled in
     on the first frame.
  4. The drawer, three times, through its own pan steps (lab verb
     `timestamps <points> <seconds> <hold>`): begin, update each frame, the
     release spring.
  5. A photo send: Delivered, then Read, then Chief's reply.
  6. The Photos drawer, then back.

  The script splits frames at 2 fps (`frames/`) and at 15 fps for each
  drawer window (`drawer-*`). `timeline.txt` holds the marks.
- Frame review: incoming and outgoing bubbles slide together, with their
  tapbacks, and spring back together. Times come in from the right edge. The
  header shows the avatar and "Chief" on every frame. The photo shows
  Delivered, then Read. The Photos drawer opens on iOS 27 with the library
  grid, and on iOS 26 with the system permission sheet showing our usage
  string. Neither OS crashed.
- Unit tests (`CmuxMobileChiefTests`) cover:
  - The mock delivers a photo and replies to it.
  - The store sends a photo and text without a failure.
  - The daemon backend runs begin, chunk and commit, and sends an
    `attachment` part followed by a `text` part.
  - The daemon backend reads incoming bytes by hash.
  - The directory lists Chief first, searches by name, and opens one agent's
    chat, or Chief for several recipients.

## Known gaps

- **No frame comparison against Messages.** Simulator Messages has no
  conversations (no iMessage account), and simctl cannot inject touches, so
  its drawer could not be recorded. The direct-chat drawer behavior that the
  package measured with a display-only hook is what Chief now overrides, at
  the user's request.
- **The lab host was not built.** It lives in their iOS app
  (`CmuxMobileShellUI`). The comparison above is a code diff. Chief now runs
  the same drawer path that the lab's default group conversation runs.
- **Incoming bubbles are clipped at the leading edge.** In a direct chat
  there is no avatar column, so they slide past the leading edge while the
  drawer is open. This is the travel the package avoided by default.
- **The daemon path still cannot reach a phone.** Resolved on
  `feat-cnx-ios-chieflive`. The phone now reaches the Mac's Chief owner
  through hostd's scoped `chief` service. See `chief-mac-parity.md` and
  `../SECURITY.md`.
- **The drawer is driven by a lab verb, not a finger.** The edge swipe was
  not recorded, for the same reason as above. It needs a hand check on a
  device.
