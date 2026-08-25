"""Register Hermes shell hooks inside TUI-owned Python processes.

Hermes's launcher registers hooks before handing the TUI to Node. Node then
starts a fresh Python gateway (and optionally a compute host), so that original
process-local registry is absent from every TUI turn. The cmux Python wrapper
adds this module through a private PYTHONPATH only for those children.
"""

from __future__ import annotations

import os
import sys
from typing import Any


_TARGET_MODULES = {"tui_gateway.entry", "tui_gateway.compute_host"}
_TARGET_MODULE_ENV = "CMUX_HERMES_TUI_TARGET_MODULE"
_WRAPPER_OWNED_LIFECYCLE = {
    "on_session_start": "session-start",
    "on_session_reset": "session-start",
    "on_session_finalize": "session-finalize",
}


def _target_module() -> str | None:
    marked_target = os.environ.get(_TARGET_MODULE_ENV)
    if marked_target in _TARGET_MODULES:
        return marked_target
    argv = getattr(sys, "orig_argv", ())
    for index, argument in enumerate(argv[:-1]):
        if argument == "-m" and argv[index + 1] in _TARGET_MODULES:
            return argv[index + 1]
    return None


def _is_wrapper_owned_lifecycle_entry(entry: Any, subcommand: str) -> bool:
    if not isinstance(entry, dict):
        return False
    command = entry.get("command")
    return isinstance(command, str) and f"hooks hermes-agent {subcommand}" in command


def _turn_hook_config(config: Any) -> Any:
    """Leave lifecycle capture to the active-session watcher.

    User lifecycle hooks stay registered in the gateway. Only cmux's matching
    lifecycle entries are removed, preventing duplicate session-start/finalize
    events while still registering every per-turn and approval callback.
    """

    if not isinstance(config, dict) or not isinstance(config.get("hooks"), dict):
        return config
    hooks = config["hooks"]
    bridged_hooks = dict(hooks)
    for event, subcommand in _WRAPPER_OWNED_LIFECYCLE.items():
        entries = hooks.get(event)
        if isinstance(entries, list):
            bridged_hooks[event] = [
                entry
                for entry in entries
                if not _is_wrapper_owned_lifecycle_entry(entry, subcommand)
            ]
    bridged_config = dict(config)
    bridged_config["hooks"] = bridged_hooks
    return bridged_config


def _bootstrap() -> None:
    target_module = _target_module()
    try:
        if os.environ.get("CMUX_HERMES_TUI_HOOK_BOOTSTRAP") != "1":
            return
        if target_module is None:
            return

        from agent.shell_hooks import register_from_config
        from hermes_cli.config import load_config

        accept_hooks = os.environ.get("HERMES_ACCEPT_HOOKS", "").strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        register_from_config(
            _turn_hook_config(load_config()),
            accept_hooks=accept_hooks,
        )
    finally:
        # Do not leak a gateway marker to unrelated Python subprocesses. A
        # later compute host routed through the wrapper receives its own marker.
        os.environ.pop(_TARGET_MODULE_ENV, None)


try:
    _bootstrap()
except Exception:
    # A notification bridge must never prevent Hermes's gateway from starting.
    pass
