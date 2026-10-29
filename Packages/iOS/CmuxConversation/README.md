# CmuxConversation host integration

`ConversationPresentationOptions.header` accepts a `ConversationHeaderPresentation`.
Its default preserves the Messages header and platform-specific wash. A host can
opt into `.system` scroll-edge treatment (iOS 26+), which reserves the entire
avatar/name header for the native soft edge, and set `transcriptTopSpacing` to
control the gap beneath that header. Before iOS 26 the existing wash remains.
Header controls, safe areas and keyboard layout remain owned by the package.

`onHeaderInfo` replaces the name/avatar details action. `onHeaderAction` receives
the trailing control as a popover anchor, only in the normal state; edit, reply
and selection still close first. Accessibility labels come from the presentation
options. Hosts do not need to inspect private header subviews or replace button
handlers. cmux NEXT's Chief uses these hooks through its path dependency.
