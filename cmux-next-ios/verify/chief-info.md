# Chief's info, laid out as Messages' contact details

Branch `feat-cmux-next-ios-chief-info-imessage`, 2026-10-23.

User report: "the spacing between the Chief circular icon and the Done button is too much here. Layout should mimic iMessage."

## Sheet or push

Messages pushes contact details from the conversation header. Its back chevron and the edge swipe return to the conversation. The Chief page was a page sheet with Done. It is now pushed on Home's navigation stack, which the app uses for every drill-down (memory: navigation stacks with swipe-back, no covers). `ChiefConversationScreen` owns the push (`navigationDestination(isPresented:)`). The header's avatar, name and trailing button and `ChiefDemoHook.openSettings` all open it.

Push details:
- `ChiefConversationContainer` hands the back-swipe recognizers back to the navigation controller in `viewWillDisappear`, as before. While a page covers it, it no longer takes them again on layout (`isCovered`).
- `session.isVisible` is false while the page is open, as when Messages shows details: Chief's alerts and unread count work as for any screen that is not the conversation.
- Message (the quick action) pops back and raises the keyboard.

CmuxConversation was not changed. This page is Chief's own (`CmuxMobileChief/ChiefSettingsView.swift`). The package stays byte-identical to `origin/feat-imsg-parity-gui`.

## Layout

Numbers come from Messages on iOS 26.5, iPhone 17 Pro (402 × 874 pt). They were read from MobileSMS's own accessibility tree in a simulator, in a sample conversation's details. CmuxConversation's `ConversationDetailsHeaderGeometry` has the same numbers.

| | Messages | Chief, before (sheet) | Chief, after (push) |
| --- | --- | --- | --- |
| Bar buttons | Back 36 pt glass circle at y 66–102 (center y 84) | Done capsule at y 82–118 (center y 100) | MEASURE |
| Avatar | 80 pt, top y 62 (status bar's bottom), center y 102 | 72 pt, top y 171, center y 207 | MEASURE |
| Avatar center − bar button center | +18 pt | +107 pt (Done) | MEASURE |
| Bar button bottom → avatar top | avatar overlaps the bar row (−40 pt) | 53 pt gap | MEASURE |
| Avatar top → name's line box | 84 pt (4 pt below the avatar) | name glyphs 24 pt below the avatar | MEASURE |
| Quick actions | 48 pt circles, 20 pt apart, top y 195.7 | none | MEASURE |
| First card | top y 263.7 | top y 394 | MEASURE |

What the page has now:
- **Bar:** the system back chevron, and Edit when the Mac is connected. Edit opens Name and, on a Mac that sets it, Avatar. Both were rows on the old page. No title in the bar, as in Messages; it still names the page for VoiceOver and the back menu.
- **Header:** the avatar (80 pt), the name (title, bold), the status line (subheadline, secondary), then the quick actions.
- **Quick actions:** Message, and Stop (dimmed unless Chief is typing; it replaces the "Stop Chief" row). Messages' call, video and mail have no meaning for Chief. Voice was left out because the Action Button call is not an action on this page. "Open on Mac" was left out because nothing on the phone can open a page on the Mac.
- **Cards:** the Model card (harness, model, effort; Try Again; the model server line), Recent Turns, the Hide Alerts and Send Read Receipts card with its footer, and "Chief's memory and traces open on the Mac." Section gaps are 20 pt, as in Messages.
- **Backdrop:** the grouped background with a blurred wash of Chief's monogram color behind the header (Messages blurs the contact's color the same way).
- The top edge blur stays off until the cards scroll under the bar. The avatar sits in the bar's row at rest.

## Live run

RESULTS
