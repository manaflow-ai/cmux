/// `tabs.nativeNewTabPage` in cmux.json (Lawrence 2026-10-29: the Swift New Tab page "an
/// alternative to current new tab page for now, dont completely replace it yet"): off by default,
/// so Cmd-T opens the web New Tab page. On, Cmd-T, the tab bar's + and New Tab Page open the native
/// one (no web view). Settings, the palette's setting toggle and `cmux settings set` all write it.
public nonisolated enum NativeNewTabPageSetting {
}
