# Swift Auxiliary Window Close Shortcuts

Standalone cmux-owned windows must have one close-shortcut owner so Cmd+W closes or hides the active window instead of falling through to workspace panel closing.

Report a failure when the diff introduces or materially changes:

- A user-visible `NSWindow`, `NSPanel`, `NSWindowController`, SwiftUI `Window`, or SwiftUI `WindowGroup` without a stable `cmux.*` window identifier.
- A `cmux.*` window identifier assignment that is missing from `cmuxAuxiliaryWindowIdentifiers` in `Sources/cmuxApp.swift`.
- A new standalone debug, settings, preview, task, editor, browser, file, import, config, or inspector window that can become key but is not covered by `cmuxWindowShouldOwnCloseShortcut`.
- A custom Cmd+W, `performKeyEquivalent`, or close-menu workaround that bypasses the shared `cmuxWindowShouldOwnCloseShortcut` routing instead of registering the window identifier.

Allowed cases:

- Main workspace windows, terminal panes, tabs, sheets, popovers, menus, and views that are not standalone key windows.
- Hidden bootstrap or internal windows explicitly documented in the script ignore list.
- Test-only fixture windows.
- Existing unregistered windows that the PR does not introduce or worsen, though mention them if they are adjacent to the changed window code.

When reporting, include the window/controller/file, the missing identifier or owner registration, and the expected shared path: assign a stable `cmux.*` identifier and register user-closable windows in `cmuxAuxiliaryWindowIdentifiers`. If the hard CI lint already catches the exact literal assignment, point to `scripts/lint_auxiliary_window_close_shortcuts.py`; otherwise explain why the bot rule caught a more flexible pattern.
