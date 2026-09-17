# acpmux (Python distribution)

**This release is a placeholder.** It holds the `acpmux` name on PyPI while the
real distribution is prepared. It contains no working multiplexer.

acpmux is *tmux for ACP agents*. A Rust daemon keeps
[Agent Client Protocol](https://agentclientprotocol.com) agents (Codex, Claude
Code, Gemini, OpenCode, Pi, ...) alive as named sessions, records every wire
message, and lets any number of clients attach, prompt, steer, cancel, fork, and
change model or mode.

A future release of this package will ship the compiled `acpmux` binary as a
Python entry point. Until then, build it from source:

```sh
git clone https://github.com/manaflow-ai/acpmux
cd acpmux
cargo build --release
```

Source and documentation: <https://github.com/manaflow-ai/acpmux>

MIT licensed.
