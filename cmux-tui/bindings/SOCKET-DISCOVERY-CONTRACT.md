# Unix socket discovery contract

SDKs resolve a socket in this order: explicit API or CLI path, non-blank
`CMUX_TUI_SOCKET`, non-blank `CMUX_MUX_SOCKET`, then a derived path under
`XDG_RUNTIME_DIR`, `TMPDIR` (or the platform temp directory), or `/tmp`.
Derived paths use `cmux-tui-<uid>/<session>.sock`.

Explicit empty paths are invalid. Session names are validated before deriving a
path. If a derived path exceeds the platform `sockaddr_un.sun_path` byte
capacity, the implementation uses the `/tmp` fallback. Explicit and inherited
paths are returned unchanged. A failed connection is a connection error, not a
second discovery attempt.

Conformance vectors should contain `explicit`, an environment map, `session`,
platform byte capacity, and one expected result: `path`, `invalid_argument`, or
`connection_error`. Each language keeps a small native resolver while sharing
these vectors, so public APIs and authority rules remain unchanged.

The contract follows the platform APIs: Python `AF_UNIX`, Go `DialUnix`, Node
IPC `path`, Java `UnixDomainSocketAddress`, C++ `AF_UNIX`, Rust Unix streams,
and Zig POSIX sockets all connect to one named local endpoint and report path
or connection failures directly.
