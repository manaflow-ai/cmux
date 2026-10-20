# C++ Binding Style

Requirements:

- Require C++20 and use no third-party runtime library.
- Use fixed-width integers, `std::variant`, and explicit missing/null wrappers.
- Return typed `Result<T>` values instead of throwing protocol errors.
- Preserve unknown events and their complete JSON objects.
- Use RAII for clients, streams, attachments, and transport shutdown.
- Bound frames, pending responses, and pre-ack events.
- Keep generated wire declarations separate from hand-written transport and convenience APIs.
- Install a CMake package with the public target `cmux::sdk`.
- Pass strict warning, installed-consumer, and sanitizer builds.
