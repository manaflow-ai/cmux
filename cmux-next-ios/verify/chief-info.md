# Chief's info, laid out as Messages' contact details

Branch `feat-cmux-next-ios-chief-info-imessage`, 2026-10-23.

User report: "the spacing between the Chief circular icon and the Done button is too much here. Layout should mimic iMessage."

## Sheet or push

Messages pushes contact details from the conversation header. Its back chevron and the edge swipe return to the conversation. The Chief page was a page sheet with Done. It is now pushed on Home's navigation stack, which the app uses for every drill-down (memory: navigation stacks with swipe-back, no covers). `ChiefConversationScreen` owns the push (`navigationDestination(isPresented:)`). The header's avatar and name and `ChiefDemoHook.openSettings` open it. (Since `feat-cmux-next-ios-chief-invite`, the trailing button is Invite to cmux; see `chief-invite.md`.)

Push details:
- `ChiefConversationContainer` hands the back-swipe recognizers back to the navigation controller in `viewWillDisappear`, as before. While a page covers it, it no longer takes them again on layout (`isCovered`).
- `session.isVisible` is false while the page is open, as when Messages shows details: Chief's alerts and unread count work as for any screen that is not the conversation.
- Message (the quick action) pops back and raises the keyboard.

CmuxConversation was not changed. This page is Chief's own (`CmuxMobileChief/ChiefSettingsView.swift`). The package stays byte-identical to `origin/feat-imsg-parity-gui`.

## Layout

Numbers come from Messages on iOS 26.5, iPhone 17 Pro (402 × 874 pt). They were read from MobileSMS's own accessibility tree in a simulator, in a sample conversation's details. CmuxConversation's `ConversationDetailsHeaderGeometry` has the same numbers.

| | Messages | Chief, before (sheet) | Chief, after (push) |
| --- | --- | --- | --- |
| Bar buttons | Back, a 36 pt circle at y 66–102 (center y 84) | Done capsule at y 82–118 (center y 100) | Back at y 62–106 and Edit at y 66–102 (both centered at y 84) |
| Avatar | 80 pt, top y 62 (the status bar's bottom), center y 102 | 72 pt, top y 182, center y 218 | 80 pt, top y 62, center y 102 |
| Avatar center minus bar button center | +18 pt | +118 pt (Done) | +18 pt (Back and Edit) |
| Bar button bottom to avatar top | the avatar overlaps the bar row | 64 pt gap | the avatar overlaps the bar row, as in Messages |
| Avatar top to the name's line box | 84 pt (4 pt under the avatar) | name glyphs 13 pt under the avatar (no line box to read) | 84 pt (4 pt under the avatar; glyphs 10 pt under it) |
| Quick actions | 48 pt circles, 20 pt apart, top y 195.7 (16 pt under the name) | none | 48 pt circles, 20 pt apart, top y 215.7 (under the name and the status line) |
| First card | top y 263.7, 20 pt under the quick actions | top y 394 | top y 283.7, 20 pt under the quick actions |

The before avatar is measured from the screenshot's pixels (the old sheet had no avatar element; its header element starts 11 pt above the disc). The first card's top comes from pixels too: the accessibility frame of a picker row starts 9 pt inside its card. Everything else comes from the accessibility tree. The status line ("Runs on cmux's Mac mini", "Chief isn't connected to a Mac") is the one row Messages does not have, so the quick actions and the first card sit 20 pt lower than in Messages. Both connected and disconnected states measure the same. Light and dark measure the same.

What the page has now:
- **Bar:** the system back chevron, and Edit when the Mac is connected. Edit opens Name and, on a Mac that sets it, Avatar. Both were rows on the old page. No title in the bar, as in Messages; it still names the page for VoiceOver and the back menu.
- **Header:** the avatar (80 pt), the name (title, bold), the status line (subheadline, secondary), then the quick actions.
- **Quick actions:** Message, and Stop (dimmed unless Chief is typing; it replaces the "Stop Chief" row). Messages' call, video and mail have no meaning for Chief. Voice was left out because the Action Button call is not an action on this page. "Open on Mac" was left out because nothing on the phone can open a page on the Mac.
- **Cards:** the Model card (harness, model, effort; Try Again; the model server line), Recent Turns, the Hide Alerts and Send Read Receipts card with its footer, and "Chief's memory and traces open on the Mac." Section gaps are 20 pt, as in Messages.
- **Colors:** as Messages, the plain system background (white, or black in dark mode) under cards in the secondary background, with a blurred wash of Chief's monogram color behind the header. The model card's pickers and Try Again are system blue; the switches are system green.
- The top edge blur stays off until the cards scroll under the bar. The avatar sits in the bar's row at rest.

## Live run

Script: `verify/chief_info_live.py`. Evidence is git-ignored, in `verify/evidence/2026-10-23/chief-info/` (copied to `~/cmux-mobile-builds/20261023-chief-info-evidence/`).

- **Mac.** A hidden, isolated rig on mini-cmuxs-mac-mini-3 (`verify/e2e/mac.py`: its own bundle id, config and credentials, launched with `open -g -j`, never activated), the fleet build `cmux-mobile-e2e-c71da43f`, with its real Chief. The first try was on mini-cmux8s, but the phone listed another rig on that mini in place of this one (rigs on one mini fold into one Mac entry), so the run moved to a mini with no other rig.
- **Phone.** One headless iOS 26.5 simulator (`cmux-chiefinfo`, iPhone 17 Pro) on the same mini, the Demo build of the base (cd7f904c9179) and of this branch, with DEBUG dev sign-in, over the real link (WireGuard direct). It was driven with AXe accessibility taps on that simulator only. Simulator.app was never opened.
- **Builds.** On mini-cmux8s with Xcode 26.6.
- **Disconnected.** The rig Mac quits with the page open; the page says "Chief isn't connected to a Mac" within 2 s.
- **Messages reference.** MobileSMS in the same simulator, a sample conversation's details, light and dark, measured from its own accessibility tree.

Checks on this branch's build, connected:

| Check | Result |
| --- | --- |
| Harness, Model and Effort pickers present | Pass |
| Hide Alerts switches on and back off | Pass (0, 1, 0) |
| Edit opens Name | Pass |
| Edge swipe from the left pops back to the conversation | Pass |
| Message returns to the conversation with the keyboard up | Pass |
| Disconnected status and the "Connect to your Mac to choose Chief's model." card | Pass |

The base build's switches work the same way (a held press flips both and they stay). The connect step's Continue in onboarding sometimes does not advance on this rig, for the base build too; the script relaunches and takes the step again.
