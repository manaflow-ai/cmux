# CmuxTerminalRenderer

`cmux-terminal-renderer` is a disposable renderer worker owned by the persistent
terminal backend. One worker serves the visible presentations in exactly one
workspace. It owns Ghostty font shaping, scene projection, Metal rendering, and
the IOSurface pool. It does not create a Ghostty Surface, PTY, parser, mailbox,
or terminal I/O thread.

The daemon passes an authenticated bidirectional socket in
`CMUX_RENDERER_CONTROL_FD`, plus `--workspace`, `--renderer-epoch`, and
`CMUX_DAEMON_INSTANCE_ID`. Semantic scenes arrive through the bounded binary
control protocol. Completed IOSurfaces leave through the capability-bearing
Mach endpoint attached to each presentation. A pool slot is released only when
the daemon returns the exact host GPU-completion acknowledgement.

After the first accepted scene for each presentation generation, the worker
reports `PresentationReady` with the exact Ghostty-owned columns, rows, cell
pixel size, and final padding. The reply is fenced to that scene's terminal and
presentation sequences, so the daemon never infers grid geometry from canvas
pixels.

`resolvedConfig` is a canonical UTF-8 Ghostty directive snapshot. It is loaded
from a synthetic path over Ghostty's built-in defaults, then finalized before
the standalone scene renderer is created. The worker does not reread user config
files. The snapshot must never contain an untrusted path or raw PTY data.
Ghostty applies configured window padding, DPI scaling, and padding balancing
inside the renderer process before publishing metrics.

Canonical scene colors contain only PTY-authored OSC 4, OSC 10/11/12, and
reverse-video state. Each presentation seeds untouched palette, foreground,
background, and cursor behavior from its own `resolvedConfig`. An OSC reset
therefore reveals that presentation's configured value without making daemon
state depend on any renderer theme.
