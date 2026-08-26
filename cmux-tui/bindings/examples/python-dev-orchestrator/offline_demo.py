#!/usr/bin/env python3
"""Run the orchestrator end to end against the deterministic fake server."""

from __future__ import annotations

from fake_cmux_server import FakeCmuxServer
from orchestrator import main


def run() -> int:
    with FakeCmuxServer(
        workspace_create_indeterminate="applied",
        workspace_close_indeterminate="not_applied",
        replayed_operations=("tab.create_terminal",),
    ) as server:
        result = main(
            (
                "--socket",
                server.path,
                "--run-id",
                "offline-demo",
                "--verbose",
            )
        )
        if server.errors:
            raise RuntimeError(f"fake server failed: {server.errors!r}")
        return result


if __name__ == "__main__":
    raise SystemExit(run())
