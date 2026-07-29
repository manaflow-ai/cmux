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

Each mutation sends one caller-visible idempotency key and never retries
implicitly. `MutationResult` contains the flat canonical value, generation,
revision, and replayed fields. Results never echo the request’s idempotency
key. `created_path()` parses a typed workspace, terminal, or browser path from
a creation result’s value.

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

Names preserve exact bytes. Workspace and machine `clear_name()` set the
empty string. Screen, pane, and tab `clear_name()` send JSON null.
`ClientMetadataUpdate` distinguishes unchanged, set (including empty), and
clear states.

Typed stream classes cover session events, terminal attachment items, browser
attachment items, sidebar view items, and provider notices. Unknown payload
fields remain available through each item’s `extra` JSON value. Stream
cancellation waits for both the response and terminal stream end, even when
the end arrives first. Structured end errors retain code, message, redacted
details, and retryability.
Provider notices are acknowledged explicitly with
`provider_scope.notice(id).acknowledge(sequence)` after the consumer paints
the notice; iteration never acknowledges delivery.

Renderer grants expose endpoint, terminal ID, rights, TTL, and a
`SensitiveString` token. Formatting a grant or provider credential prints
`[REDACTED]`.

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
