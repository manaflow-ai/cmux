# cmux resource SDK for C++20

The SDK has no third-party runtime dependencies. The default API uses typed
opaque resource IDs, explicit handles, `cmux::result<T>`, cryptographically
random mutation keys, and move-only RAII streams.

```cpp
#include <cmux/client.hpp>

auto connected = cmux::Client::connect();
if (!connected) {
    std::cerr << connected.error().message << '\n';
    return 1;
}
auto client = std::move(connected).value();

auto parsed = cmux::WorkspaceId::parse(
    "ws_0123456789abcdef0123456789abcdef");
auto command = cmux::RunCommand::exact(
    {"cargo", "test", "--workspace"});
if (!parsed || !command) {
    return 1;
}

cmux::RunOptions run(std::move(command).value());
run.cwd = "/checkout";
auto started = client.workspace(std::move(parsed).value()).run(
    std::move(run),
    cmux::MutationOptions::unique().expecting(42));
```

`RunCommand::exact` preserves each argument. `RunCommand::shell` sends a
script for the server platform default shell. Choosing a shell executable
uses `RunCommand::shell_with_executable`, which encodes exact
`[executable, "-lc", script]` arguments.

Every operation returning `CreatedPath`, `CreatedTerminalPath`, or
`CreatedBrowserPath` accepts an optional validated `correlation_key` through
its typed creation options. The key is independent of the mutation
idempotency key and can be resolved later with `Session::resolve_creation()`.

Each mutation sends one caller-visible idempotency key and never retries
implicitly. `MutationResult<T>` contains the exact typed catalog value,
generation, revision, and replayed fields. A transport failure after a
mutation write returns `ErrorCode::outcome_uncertain` with the exact operation
and idempotency key. `Client::mutate` remains the explicit raw JSON escape
hatch.

`CallOptions` supplies a steady-clock deadline and `std::stop_token` for an
individual raw call, `Workspace::run`, or stream open.
`ResourceStream::poll(timeout)` bounds a stream wait.

`TerminalHistoryOptions` validates `limit` in the range 1 through 10000 and
encodes the full unsigned `before` cursor as a decimal string.
`TerminalAttachOptions` requires `cols` and `rows` together and exposes a
typed `read_only` flag.

The socket binds a client to its current machine and session. The client adds
those routing selectors when callers supply only an opaque target ID.
`ClientOptions::machine_selector` and `session_selector` can select another
route. Direct opaque nested IDs remain globally addressable without repeating
their structural ancestors.

Every resource factory also accepts `Selector<Id>::by_id(id)`,
`Selector<Id>::current()`, or `Selector<Id>::exact_name(name)`. Child factories
retain the complete parent route without performing I/O:

```cpp
auto terminal =
    client.session(cmux::Selector<cmux::SessionId>::current())
        .workspace(
            cmux::Selector<cmux::WorkspaceId>::exact_name("build"))
        .screen(cmux::Selector<cmux::ScreenId>::current())
        .pane(cmux::Selector<cmux::PaneId>::exact_name("tests"))
        .tab(cmux::Selector<cmux::TabId>::current())
        .terminal(cmux::Selector<cmux::TerminalId>::current());

auto visible = terminal.read_screen();
```

Exact names are tagged as `name:` on the wire, so names equal to `current` or
an opaque ID remain names. Nested handles send every supplied ancestor, which
lets the server reject a mismatched parent before an operation runs. A direct
current or name selector fills missing structural ancestors with `current`;
chain from an explicit parent when that context should differ. Constructing,
copying, and destroying handles performs no I/O. `selected_id()` is populated
for ID selectors. `refresh()` resolves the opaque ID for current and name
selectors from the server snapshot.

Names preserve exact bytes. Workspace `clear_name()` sets the empty string.
Screen, pane, and tab `clear_name()` send JSON null.
`ClientMetadataUpdate` distinguishes unchanged, set (including empty), and
clear states.

Typed stream classes cover session events, terminal attachment items, browser
attachment items, and sidebar view items. Recognized
variants reject unknown sibling fields. Unrecognized variants preserve the
complete object in `Unknown::raw`. Stream
cancellation waits for both the response and terminal stream end, even when
the end arrives first. Structured end errors retain code, message, redacted
details, and retryability. Attachment `resize_viewer()` and
`release_viewer()` calls use the dedicated
stream connection. Handle methods use the control connection.

Renderer grants expose endpoint, terminal ID, rights, TTL, and a
`SensitiveString` token. Formatting a grant prints `[REDACTED]`.

`TerminalSnapshot` exposes `lifecycle` plus a typed exit outcome.
`Session::resolve_creation()` and `Terminal::wait_exit()` remain separate from
terminal text matching.

`Screen::undo_layout()` requires the preview's confirmation token when
`confirm_close` is true. Decode a `confirmation.required` error with
`decode_confirmation_required_details()` to obtain its token, revision, and
closing pane IDs.

Generated protocol-v10 compatibility APIs remain available only through the
explicit raw namespace:

```cpp
#include <cmux/raw/client.hpp>

cmux::raw::Client legacy_client;
```

Build and test:

```sh
cmake -S . -B build -DCMAKE_CXX_COMPILER=clang++
cmake --build build
ctest --test-dir build --output-on-failure
```
