# cmux-tui C++ SDK

The C++20 SDK has no third-party runtime dependencies. It provides exact
64-bit protocol IDs, bounded JSON parsing, Unix JSON-lines transport, an
injectable message transport for WebSocket hosts, typed protocol-v10 commands,
and closeable RAII streams. The package version is 0.4.0.

```cpp
#include <cmux/client.hpp>

auto connected = cmux::Client::connect();
if (!connected) {
    std::cerr << connected.error().message << '\n';
    return 1;
}

auto client = std::move(connected).value();
auto identity = client.identify();
if (!identity) {
    std::cerr << identity.error().message << '\n';
    return 1;
}
std::cout << identity.value().session << '\n';
```

Clients enable control, frontend, and local-admin commands by default.
Provider-owned workspace mutations require an explicit authority opt-in:

```cpp
cmux::ClientOptions options;
options.authorities.provider_authority = true;
auto provider_client = cmux::Client::connect(std::move(options));
```

Without that opt-in, provider-authority methods return
`ErrorCode::authority` before writing to the transport. Individual default
authorities can also be disabled through `ClientOptions::authorities`.

The first generated command lazily sends `identify` on the control connection.
The client caches the reported protocol and capabilities, then checks command
and present-field requirements before writing the requested command. Unsupported
commands return `ErrorCode::unsupported`; an explicitly null optional field is
present and receives the same compatibility check as a value.

Requests expose generated structs, so the compiler checks field names and
types. Optional wire fields use `std::optional`; nullable fields retain an
explicit null state. Unknown events retain their wire name and complete JSON
object.

```cpp
cmux::ReadScreenRequest request{.surface = cmux::Id{7}};
auto screen = client.read_screen(request);

cmux::AttachSurfaceRequest attach{.surface = cmux::Id{7}};
auto opened = client.attach_bytes(attach);
if (opened) {
    auto stream = std::move(opened).value();
    if (auto event = stream.next()) {
        if (const auto* output = std::get_if<cmux::OutputEvent>(&event.value().value)) {
            auto bytes = cmux::base64_decode(output->data.value);
        }
    }
}  // Stream destruction closes its dedicated connection.

auto deltas = client.subscribe_deltas();
```

`attach_bytes`, `attach_render`, `attach_browser`, and `subscribe_deltas`
select their wire modes and return named stream types. The canonical generated
`attach_surface` and `subscribe` methods expose the complete protocol request.
Every stream supports `next(timeout)`, `close()`, and `closed()`.

Render frontends that resize a surface should use `RenderAttachment`. Size
leases belong to the connection that created them, so the attachment routes
resize, sizing, and release commands through its own stream connection. It
also exposes that connection's server-assigned client ID without comparing
global client lists:

```cpp
cmux::AttachSurfaceRequest request{
    .cols = std::uint16_t{120},
    .rows = std::uint16_t{40},
    .surface = cmux::Id{7},
};
auto opened = cmux::open_render_attachment(request);
if (!opened) {
    std::cerr << opened.error().message << '\n';
    return 1;
}

auto attachment = std::move(opened).value();
std::cout << "render client " << attachment.client_id() << '\n';
auto resized = attachment.resize(132, 44);
auto exclusive = attachment.set_sizing(true, true);
auto event = attachment.next(std::chrono::seconds(1));
auto released = attachment.release_size();
```

`RenderAttachment::connect` is the equivalent static factory. Attachments are
move-only and close their dedicated connection on destruction. Events received
before attach acknowledgement or while a sizing command is pending retain
their wire order. `max_buffered_stream_events` bounds that queue.

For a WebSocket integration, implement `cmux::Transport` and pass factories in
`cmux::ClientOptions`. The host chooses its WebSocket and TLS library:

```cpp
cmux::ClientOptions options;
options.transport_factory = []() -> cmux::Result<std::unique_ptr<cmux::Transport>> {
    return connect_application_websocket();
};
options.stream_transport_factory = options.transport_factory;
auto client = cmux::Client::connect(std::move(options));
```

`RenderAttachment` can call `send` while its router is blocked in `receive`.
Injected transports must support one concurrent sender and receiver. The
built-in Unix transport provides this synchronization.

Build and test:

```sh
cmake -S . -B build -DCMAKE_CXX_COMPILER=clang++
cmake --build build
ctest --test-dir build --output-on-failure
```
