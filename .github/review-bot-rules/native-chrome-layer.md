# Native Chrome Layer

Flag changes to the cmux NEXT macOS app that draw native chrome or Home in a web view. The rule and its decision test are in `plans/cmux-next/language-layers.md`: Home and native chrome are Swift (AppKit); only the agent chat pane and full tab pages are React; logic with no view is Rust.

Report a failure when the diff:

- Deletes or empties AppKit view files and adds or grows a directory under `webviews/src/pages/` for the same surface.
- Hosts a `PageWebView` (or any `WKWebView`) inside a popover, bubble, sheet, dialog, toast, toolbar, bar, sidebar section or row, card, or overlay window.
- Creates one web view per bar, row, card or list item.
- Draws toasts, dialogs or other chrome on a transparent web overlay above native views.
- Moves a Home surface (transcript, conversation list, Chief panel, a Home sheet) into a web page.
- Moves a surface that the Command Palette (Cmd+Shift+P) opens, a palette page, or a palette preview into a web page.
- Adds a `debt` or `review` row to `scripts/cmux-next/react-pages.tsv`, or adds a `page` row for a surface that is attached to a native view.
- Adds a page directory under `webviews/src/pages/` with no row in `scripts/cmux-next/react-pages.tsv`.

Signals that the surface is native chrome:

- It is anchored to a native control or to the window frame.
- It shares a first responder, focus ring, text input or drag pasteboard with the AppKit views beside it.
- It has to appear on the first frame after a click or a key press.
- The person can reach it from Cmd+Shift+P.

Allowed cases:

- Changes inside the agent chat pane (`webviews/src/agent-session/**`).
- A new full tab page with scrolling content and no native neighbor inside its bounds, with a `page` row and the decision test's answers in the pull request description.
- Changes to an existing `page` row's page that keep it a full tab page.
- Moving a `debt` or `review` surface back to AppKit and deleting its row.
- Rust changes that move state or logic out of Swift without changing which layer draws it.

Line count is not a defense: a move that removes more Swift than it adds React still fails when the surface is native chrome.

When reporting, name the surface, the question of the decision test that it fails, and the AppKit view or helper that should draw it.
