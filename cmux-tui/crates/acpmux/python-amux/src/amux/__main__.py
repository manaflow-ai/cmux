"""Entry point for the placeholder distribution."""

import sys

from . import __version__

MESSAGE = f"""amux {__version__} (placeholder distribution)

This PyPI package does not contain the multiplexer yet. amux is a Rust
daemon; build it from source:

    git clone https://github.com/manaflow-ai/acpmux
    cd acpmux
    cargo build --release

A future release of this package will ship the compiled binary.
"""


def main() -> int:
    print(MESSAGE, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
