# Gesture matrix: which view a touch belongs to

Leo, 2026-11-23: "when i try to scroll in the composer in ios it ... swipes the entire thing down instead of
scrolling through the composer. there are no doubt dozens of ... interactions like this which should've just very
easily been caught and understood and iterated on."

## The rule

The innermost view that can use a gesture owns it, as in the ChatGPT and Claude iOS apps and Safari:

- Text being edited owns every drag that starts on it: a caret or selection drag, a long draft's scroll. A host's
  swipe-down-to-dismiss acts only on a draft that fits or sits at its top (`ComposerTextDragClaim`).
- A scroll view owns drags along an axis it can scroll; its container gets the drag only at that edge (a sheet drags
  down once its list is at the top).
- The full-width back swipe (iOS 26 content pop) never starts on text being edited, a view wider than its bounds,
  or a web page (`NavigationPopExclusion.startsOnOwnDrag`). The edge swipe back always works.
- A recognizer that runs simultaneously with others checks where the touch started; "simultaneous with everything"
  is a bug unless that is its whole point (a pinch that never cancels touches).

## Cells

Surfaces: agent chat (pushed and as a workspace tab), Chief, terminal, browser (native and streamed), artifacts,
feed, home and workspaces, sidebar, tab overview and toolbar, sheets, settings. Gestures: vertical pan, horizontal
swipe, edge or content back swipe, long press, pinch, interactive keyboard dismissal, sheet drag, pull to refresh,
bar and card swipes. Only the pairs where two recognizers can both take a touch are cells; the rest have one owner.

Status: OK (right today), FIXED (wrong before, fixed in #52373), OPEN (wrong, its PR or issue named).
Test: the `GestureConflictUITests` method that guards it, or the unit suite.

| # | Surface | Region x gesture | Should | Status | Test or PR |
|---|---|---|---|---|---|
| 1 | Agent chat (pushed) | long draft x drag down | draft scrolls, keyboard stays | FIXED | `testChat_ComposerLongDraft_DragDown_ScrollsText` |
| 2 | Agent chat (tab) | long draft x drag down | draft scrolls, keyboard stays | FIXED | `testWorkspaceChat_ComposerLongDraft_DragDown_ScrollsText` |
| 3 | Agent chat | short draft x swipe down | keyboard goes down | OK | `testChat_ComposerShortDraft_SwipeDown_LowersKeyboard` |
| 3b | Agent chat | long draft at its top x swipe down | keyboard goes down | OK | `testChat_ComposerLongDraftAtTop_SwipeDown_LowersKeyboard` |
| 4 | Terminal | long draft x drag down | draft scrolls | OK | `testTerminal_ComposerLongDraft_DragDown_ScrollsText` |
| 5 | Terminal | composer editing x swipe right | caret moves, no back | FIXED | `testTerminal_ComposerEditing_SwipeRight_StaysInWorkspace` |
| 6 | Agent chat (tab) | composer editing x swipe right | caret moves, no back | FIXED | `testWorkspaceChat_ComposerEditing_SwipeRight_StaysInWorkspace` |
| 7 | Terminal | wide output x horizontal pan | output pans, no back | FIXED | wide-scroller rule; UI test to add |
| 8 | Terminal | wide TUI x horizontal pan | TUI pans, no back | FIXED | wide-scroller rule; UI test to add |
| 9 | Browser (native) | page x horizontal swipe | page history, no workspace back | FIXED | web-view rule; UI test to add |
| 10 | Artifacts | code x horizontal scroll | code scrolls, no back | FIXED | wide-scroller rule |
| 11 | Artifacts (multi-file) | code x horizontal scroll vs file pager | code scrolls; pager from outside the code | OPEN | cluster C |
| 12 | Browser (streamed) | page x horizontal pan | page pans, no back | OPEN | cluster A |
| 13 | Browser (streamed) | page x pinch | page zooms or tab zoom, one owner | OPEN | cluster A |
| 14 | Tabs | whole screen x pinch | starts only on page or grid content | OPEN | cluster A |
| 15 | Tabs | toolbar x bar swipe | switches tabs, no back | OPEN | cluster A |
| 16 | Tabs | overview card x close swipe | card closes, no back | OPEN | cluster A |
| 17 | Tabs | overview x vertical scroll vs card swipe | grid scrolls | OK | TabsKit CardSwipe tests |
| 18 | Tabs | card x long press vs swipe | menu, or swipe after slop | OK | |
| 19 | Tabs | card x reorder drag vs scroll | scroll before lift | OK | `TabReorderUITests` |
| 20 | Tabs | bottom bar x swipe up | overview zoom, page untouched | OK | TabsKit BarSwipe tests |
| 21 | Agent chat | transcript x vertical / interactive dismissal | scrolls, keyboard follows | OK | `TranscriptTapDismissUITests` |
| 22 | Agent chat | text x long press | in-place text selection, never lifts the bubble or selects a whole chunk | OWNED: lane `ios-long-press-select` (ask-18247cdaa6) | its cells in `GestureConflictUITests` |
| 23 | Agent chat | find field x drag | field edits | OK | |
| 24 | Chief | bubble x reply swipe vs scroll | reply only on rightward bubble drags | OK | |
| 25 | Chief | bubble text x long press | in-place text selection, never lifts the bubble | OWNED: lane `ios-long-press-select` (ask-18247cdaa6) | its cells in `GestureConflictUITests` |
| 26 | Chief | long draft x swipe down | draft scrolls until top | OK | |
| 27 | Chief | back swipe x reply or caret | edge strip only | OK | |
| 28 | Chief settings | text field x content pop | caret moves, no back | OPEN (unverified: UIKit's own delegate) | cluster C |
| 29 | Terminal | TUI x vertical pan vs selection | each owns its touch | OK | `TerminalTUILocalPanUITests` |
| 30 | Terminal | text x long press, handles | in-place selection at the finger, not a whole chunk | OWNED: lane `ios-long-press-select` (ask-18247cdaa6) | its cells in `GestureConflictUITests` |
| 31 | Terminal | key bar x horizontal scroll, joystick | key bar, no back | OK | |
| 32 | Terminal | output x interactive dismissal | keyboard follows | OK | `TerminalKeyboardNoResizeUITests` |
| 33 | Artifacts | image x pinch, pan, dismiss drag | zoom first, dismiss when fitted | OK | |
| 34 | Feed | row x vertical vs trailing swipe | scroll vertical | OK | `FeedSwipeActionsUITests` |
| 35 | Feed | reply field x drag vs row swipe | text owns it | OPEN | cluster B |
| 36 | Feed | command card x horizontal scroll vs row swipe | code scrolls | OPEN | cluster B |
| 37 | Feed | jump in flight x tap on a control | control works | OPEN | cluster B |
| 38 | Feed | row x tap on a control vs row open | control wins | OPEN | cluster B |
| 39 | Feed | top x pull to refresh | only from the top | OK | |
| 40 | Feed | list x interactive dismissal | keyboard follows | OK | |
| 41 | Home, workspaces | search results x drag with keyboard | keyboard follows the finger (interactive) | OPEN | cluster C |
| 42 | Home, workspaces | rows x scroll, swipe, long press | native | OK | `HomeRowSwipeUITests` |
| 43 | Home, workspaces | top x pull to search, refresh | only from the top | OK | |
| 44 | Sidebar | search field x rightward drag | caret moves, drawer stays shut | OPEN | cluster B |
| 45 | Sidebar | drawer pan x simultaneous scroll views | only the touched scroller | OPEN | cluster B |
| 46 | Sidebar | RTL x drawer vs row actions | same direction rule | OPEN | cluster B |
| 47 | Sidebar | edge x two-axis scroller | back only once the edge swipe began | OPEN | cluster B |
| 48 | Sidebar | content x drawer vs vertical scroll | scroll vertical | OK | |
| 49 | Sheets | agent chooser, devices list x drag | list scrolls first (`.presentationContentInteraction(.scrolls)`) | OPEN | cluster C |
| 50 | Sheets | Chief message x drag down with a draft | keeps the draft (confirm or refuse) | OPEN | cluster C |
| 51 | Sheets | prompt edit `TextEditor` x sheet drag | editor scrolls, sheet at top | OK | |
| 52 | Sheets | task options, artifacts x drag | list first | OK | |
| 53 | Settings | lists x pull to refresh | only from the top | OK | |
| 54 | Shell tabs | content x tab switch | tab bar only | OK | |
| 55 | Workspace | leading edge x back | back | OK | |

Totals: 56 cells; 26 wrong before (1, 2, 5-16, 28, 35-38, 41, 44-47, 49, 50); 9 fixed here; 17 open, each in a cluster
below.

## Open clusters

- A, tabs and streamed browser (12-16): the content pop and `ZoomPinchGesture` take touches on the toolbar, cards and
  the streamed page. Register the toolbar capsule and overview cards with `NavigationPopExclusion` (TabsKit takes a
  region hook), give the stream view the web-view rule, and let the pinch start only on page or grid content.
- B, feed and sidebar (35-38, 44-47): parent recognizers that never look at the touched view.
- C, sheets, lists and Chief settings (11, 28, 41, 49, 50).

The cluster PRs are linked here as they open.
