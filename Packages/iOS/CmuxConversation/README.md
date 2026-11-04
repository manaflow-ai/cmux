# CmuxConversation host integration

`ConversationPresentationOptions.header` accepts a `ConversationHeaderPresentation`.
Its default preserves the Messages header and platform-specific wash. A host can
opt into `.system` scroll-edge treatment (iOS 26+), which combines the native soft
edge with translucent blur material through the floating avatar/name header.
The material fades below the name; transcript and reply content remain intact
and can scroll underneath it. `transcriptTopSpacing` optionally controls the
resting gap beneath the header; Chief keeps the default spacing. Before iOS 26 the existing wash remains.
Header controls, safe areas and keyboard layout remain owned by the package.

`onHeaderInfo` replaces the name/avatar details action. `onHeaderAction` receives
the trailing control as a popover anchor, only in the normal state; edit, reply
and selection still close first. Accessibility labels come from the presentation
options. Hosts do not need to inspect private header subviews or replace button
handlers. cmux NEXT's Chief uses these hooks through its path dependency.

## Reply with Selection and text size

`onReplyWithSelection` adds "Reply with Selection" to the edit menu of a
bubble's selected text (the long-press menu's Select). It ends the selection
and hands the host a `ConversationSelectionReply`: the message id and the
selected words, trimmed. `markdownQuote` writes them as the Mac's quote
("> " before each line, then an empty line). A host usually answers with
`beginReply(toMessageID:composerText:)`, which opens that message's reply as
the long-press Reply does, with the quote in the composer. Unset, the menu is
the system's alone.

`textSize` (a `ConversationTextSize`, one per Dynamic Type category) draws
the conversation at that size instead of the person's own: the controller's
traits carry it and every row re-measures as for a Dynamic Type change.
`stepped(by:)` and `percent(of:)` give a host Zoom In, Zoom Out and Actual
Size. nil, the default, follows the system.
