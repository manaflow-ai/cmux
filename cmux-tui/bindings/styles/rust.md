# Rust Binding Style

Requirements:

- Generate typed request and response structs with Serde.
- Use snake_case public methods and kebab-case wire names.
- Return `Result<T, CmuxError>`.
- Preserve absent, null, and present values as distinct states.
- Preserve unknown events and their complete JSON objects.
- Preserve command, transport, timeout, decode, and protocol-version error categories.
- Use bounded blocking streams with a close handle that unblocks another thread.
- Keep topology and other ergonomic helpers in hand-written modules.
- Support the minimum Rust version declared by the crate.
- Pass generation drift, rustfmt, clippy, rustdoc, tests, and `cargo package`.
