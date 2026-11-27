/// `tabs.hideLoneChatTab` in cmux.json: a chat alone in its pane hides its one tab, so the page shows
/// through the tab row with only the chat's tools and the pane's toolbar left in it (#33132). Off by default:
/// the strip shows at every tab count (#34327). Leo (2026-11-03): "we can put it back, just make it
/// unobtrusive, it's a bit too funky with NO top bar at all ... maybe you can leave it as an optional toggle
/// feature for now that we can revisit later". Settings, the palette's setting toggle and `cmux settings set` write it.
public nonisolated enum LoneChatTabSetting {
}
