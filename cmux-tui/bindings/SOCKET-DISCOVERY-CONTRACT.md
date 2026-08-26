# Unix socket discovery contract (target)

The intended shared behavior is: explicit API or CLI path, non-blank
`CMUX_TUI_SOCKET`, non-blank `CMUX_MUX_SOCKET`, then a derived path under
`XDG_RUNTIME_DIR`, `TMPDIR` (or the platform temp directory), or `/tmp`.
Derived paths use `cmux-tui-<uid>/<session>.sock`.

This file is a target contract, not a claim that every current SDK already
implements each rule. In particular, Node currently uses the platform temp
directory and Python/TypeScript do not perform the same session/path checks as
the other SDKs. Empty explicit values and path-length handling also differ.
Those gaps need focused implementation and vector-test changes before this
document can become normative.

The target rules are: reject explicit empty paths; validate sessions before
deriving a path; use the platform `sockaddr_un.sun_path` byte capacity (including
the trailing NUL rule) before selecting the `/tmp` fallback; return explicit and
inherited paths unchanged; and classify failed connections as connection errors
without a second discovery attempt.

Future conformance vectors should contain `explicit`, an environment map, `session`,
platform byte capacity, and one expected result: `path`, `invalid_argument`, or
`connection_error`. Each language keeps a small native resolver while sharing
these vectors, so public APIs and authority rules remain unchanged.

The contract follows the platform APIs: Python `AF_UNIX`, Go `DialUnix`, Node
IPC `path`, Java `UnixDomainSocketAddress`, C++ `AF_UNIX`, Rust Unix streams,
and Zig POSIX sockets all connect to one named local endpoint and report path
or connection failures directly.
