# Rust Binding Style

Rust generation is not run this round.

Future requirements:

- Generate typed request and response structs with Serde.
- Use snake_case public methods and kebab-case wire names.
- Return `Result<T, CmuxError>`.
- Provide non-exhaustive event enums with an unknown-event fallback.
- Preserve command, transport, timeout, decode, and protocol-version error categories.
- Expose blocking streams first; async adapters can come later.
