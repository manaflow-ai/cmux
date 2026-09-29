# CmuxTerminalCore

Terminal path resolution the cmux CLI shares: `TerminalPathResolver` and
`RemoteTerminalPathResolver` turn text a terminal printed (paths, `file://`
URLs, `path:line:col` tokens) into file references. `cmux open` uses it.

The rest of this package (Ghostty config, surfaces, key events, rendering) was
the legacy app's terminal core and was deleted with that app; cmux-next owns
its terminal in `Packages/macOS/CmuxNext/Sources/CmuxNextTerminal`.
