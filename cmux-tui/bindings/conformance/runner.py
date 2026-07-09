#!/usr/bin/env python3
from __future__ import annotations

import dataclasses
import json
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List


ROOT = Path(__file__).resolve().parents[3]
MUX_DIR = ROOT / "cmux-tui"
PYTHON_BINDING = MUX_DIR / "bindings" / "python"
FIXTURES = Path(__file__).resolve().with_name("fixtures.json")

sys.path.insert(0, str(PYTHON_BINDING))

from cmux import CommandError, CmuxClient, TimeoutError as CmuxTimeoutError  # noqa: E402


class FixtureFailure(Exception):
    pass


class FixtureSkipped(Exception):
    pass


def main() -> int:
    server = start_server()
    passed = 0
    failed = 0
    skipped = 0
    try:
        data = json.loads(FIXTURES.read_text())
        defaults = data.get("defaults", {})
        for fixture in data.get("fixtures", []):
            try:
                run_fixture(fixture, defaults, server["socket"])
            except FixtureSkipped as exc:
                skipped += 1
                print(f"SKIP {fixture.get('name', '<unnamed>')}: {exc}")
            except Exception as exc:
                failed += 1
                print(f"FAIL {fixture.get('name', '<unnamed>')}: {exc}")
            else:
                passed += 1
                print(f"PASS {fixture.get('name', '<unnamed>')}")
    finally:
        stop_server(server["process"])
    print(f"fixtures: {passed} passed, {skipped} skipped, {failed} failed")
    return 0 if failed == 0 else 1


def start_server() -> Dict[str, Any]:
    binary = MUX_DIR / "target" / "debug" / "cmux-tui"
    if not binary.exists():
        raise SystemExit(f"missing server binary: {binary}; run cargo build -p cmux-tui from cmux-tui/")
    session = f"binding-conf-{os.getpid()}"
    process = subprocess.Popen(
        [str(binary), "--headless", "--session", session],
        cwd=str(MUX_DIR),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    deadline = time.time() + 15
    socket_path = None
    lines: List[str] = []
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    while time.time() < deadline:
        for key, _ in selector.select(timeout=0.1):
            line = key.fileobj.readline()
            if line:
                lines.append(line.rstrip())
                match = re.search(r"control socket at (.+)$", line)
                if match:
                    socket_path = match.group(1).strip()
                    break
        if socket_path is not None:
            break
        if process.poll() is not None:
            raise SystemExit(f"server exited before socket path: {'; '.join(lines)}")
    selector.close()
    if socket_path is None:
        stop_server(process)
        raise SystemExit(f"timed out waiting for socket path: {'; '.join(lines)}")
    deadline = time.time() + 5
    while not Path(socket_path).exists() and time.time() < deadline:
        time.sleep(0.05)
    if not Path(socket_path).exists():
        stop_server(process)
        raise SystemExit(f"socket path was printed but does not exist: {socket_path}")
    return {"process": process, "socket": socket_path}


def stop_server(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def run_fixture(fixture: Dict[str, Any], defaults: Dict[str, Any], socket_path: str) -> None:
    check_requires(fixture, socket_path)
    variables: Dict[str, Any] = {}
    streams: Dict[str, Any] = {}
    timeout_ms = int(fixture.get("timeout_ms", defaults.get("timeout_ms", 5000)))
    with CmuxClient(socket_path=socket_path, timeout=max(timeout_ms / 1000.0, 1.0)) as client:
        try:
            for step in fixture.get("steps", []):
                step_timeout = int(step.get("timeout_ms", timeout_ms))
                run_step(client, step, variables, streams, step_timeout)
        finally:
            for stream in streams.values():
                stream.close()


def run_step(
    client: CmuxClient,
    step: Dict[str, Any],
    variables: Dict[str, Any],
    streams: Dict[str, Any],
    timeout_ms: int,
) -> None:
    step_type = step.get("type", "command")
    if step_type == "command":
        request = substitute(step["request"], variables)
        response = execute_command(client, request)
        assert_match(response, substitute(step.get("expect", {}), variables), step.get("match", "partial"))
        bind_variables(response, step.get("bind", {}), variables)
    elif step_type == "stream":
        request = substitute(step["request"], variables)
        if request.get("cmd") != "subscribe":
            raise FixtureFailure(f"unsupported stream command {request.get('cmd')}")
        stream = client.subscribe_with_request(request)
        streams[step["name"]] = stream
        response = stream.response
        assert_match(response, substitute(step.get("expect", {}), variables), step.get("match", "partial"))
    elif step_type == "expect_events":
        stream = streams[step["stream"]]
        expected = substitute(step.get("expect", []), variables)
        expect_events(stream, expected, timeout_ms / 1000.0)
    elif step_type == "wait_contains":
        request = substitute(step["request"], variables)
        wait_contains(client, request, step["path"], step["contains"], timeout_ms / 1000.0)
    else:
        raise FixtureFailure(f"unknown step type {step_type}")


def execute_command(client: CmuxClient, request: Dict[str, Any]) -> Dict[str, Any]:
    cmd = request["cmd"]
    params = {k: v for k, v in request.items() if k not in ("id", "cmd")}
    try:
        result = dispatch(client, cmd, params)
        data = result_to_data(result)
        return {"id": request.get("id"), "ok": True, "data": data}
    except CommandError as exc:
        return {"id": request.get("id"), "ok": False, "error": exc.message}


def check_requires(fixture: Dict[str, Any], socket_path: str) -> None:
    commands = fixture.get("requires", {}).get("commands", [])
    if not commands:
        return
    unsupported: List[str] = []
    with CmuxClient(socket_path=socket_path, timeout=3.0) as client:
        for command in commands:
            response = client.request(command)
            error = str(response.get("error", ""))
            if response.get("ok") is False and "unknown variant" in error:
                unsupported.append(command)
    if unsupported:
        raise FixtureSkipped(f"server lacks required command(s): {', '.join(unsupported)}")


def dispatch(client: CmuxClient, cmd: str, params: Dict[str, Any]) -> Any:
    mapping = {
        "identify": client.identify,
        "ping": client.ping,
        "reload-config": client.reload_config,
        "set-window-title": client.set_window_title,
        "clear-window-title": lambda **kw: client.clear_window_title(),
        "list-workspaces": client.list_workspaces,
        "export-layout": client.export_layout,
        "apply-layout": client.apply_layout,
        "send": lambda **kw: client.send(kw["surface"], text=kw.get("text"), bytes_data=kw.get("bytes")),
        "read-screen": client.read_screen,
        "vt-state": client.vt_state,
        "new-tab": client.new_tab,
        "new-browser-tab": client.new_browser_tab,
        "new-workspace": client.new_workspace,
        "new-screen": client.new_screen,
        "split": client.split,
        "set-ratio": client.set_ratio,
        "pane-neighbor": client.pane_neighbor,
        "focus-direction": client.focus_direction,
        "swap-pane": client.swap_pane,
        "zoom-pane": client.zoom_pane,
        "process-info": client.process_info,
        "set-default-colors": client.set_default_colors,
        "close-surface": client.close_surface,
        "close-pane": client.close_pane,
        "close-screen": client.close_screen,
        "close-workspace": client.close_workspace,
        "rename-pane": client.rename_pane,
        "rename-surface": client.rename_surface,
        "rename-screen": client.rename_screen,
        "rename-workspace": client.rename_workspace,
        "resize-surface": client.resize_surface,
        "focus-pane": client.focus_pane,
        "select-tab": client.select_tab,
        "select-screen": client.select_screen,
        "select-workspace": client.select_workspace,
        "move-tab": client.move_tab,
        "move-workspace": client.move_workspace,
        "scroll-surface": client.scroll_surface,
        "wait-for": lambda **kw: client._request("wait-for", **kw),
        "run": lambda **kw: client._request("run", **kw),
        "send-key": lambda **kw: client._request("send-key", **kw),
        "copy": lambda **kw: client._request("copy", **kw),
        "ids": lambda **kw: client._request("ids", **kw),
        "notify": lambda **kw: client._request("notify", **kw),
        "list-agents": lambda **kw: client._request("list-agents", **kw),
        "report-agent": lambda **kw: client._request("report-agent", **kw),
    }
    if cmd not in mapping:
        raise FixtureFailure(f"unsupported fixture command {cmd}")
    return mapping[cmd](**params)


def result_to_data(result: Any) -> Any:
    if dataclasses.is_dataclass(result):
        data = dataclasses.asdict(result)
        return {} if data == {} else data
    return result


def bind_variables(response: Dict[str, Any], bind: Dict[str, str], variables: Dict[str, Any]) -> None:
    for name, path in bind.items():
        variables[name] = get_path(response, path)


def substitute(value: Any, variables: Dict[str, Any]) -> Any:
    if isinstance(value, str) and value.startswith("$"):
        name = value[1:]
        if name not in variables:
            raise FixtureFailure(f"unknown fixture variable {value}")
        return variables[name]
    if isinstance(value, list):
        return [substitute(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, variables) for key, item in value.items()}
    return value


def assert_match(actual: Any, expected: Any, mode: str) -> None:
    if mode == "exact":
        if actual != expected:
            raise FixtureFailure(f"exact mismatch\nexpected: {expected}\nactual: {actual}")
        return
    if mode != "partial":
        raise FixtureFailure(f"unknown match mode {mode}")
    if not partial_match(actual, expected):
        raise FixtureFailure(f"partial mismatch\nexpected: {expected}\nactual: {actual}")


def partial_match(actual: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False
        return all(key in actual and partial_match(actual[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) < len(expected):
            return False
        return all(partial_match(actual[index], value) for index, value in enumerate(expected))
    return actual == expected


def expect_events(stream: Any, expected: List[Dict[str, Any]], timeout: float) -> None:
    index = 0
    deadline = time.time() + timeout
    while index < len(expected) and time.time() < deadline:
        remaining = max(deadline - time.time(), 0.1)
        old_timeout = stream._conn.sock.gettimeout()
        stream._conn.sock.settimeout(remaining)
        try:
            try:
                event = next(stream).raw
            except CmuxTimeoutError:
                break
        finally:
            stream._conn.sock.settimeout(old_timeout)
        if partial_match(event, expected[index]):
            index += 1
    if index < len(expected):
        raise FixtureFailure(f"expected event not observed before timeout: {expected[index]}")


def wait_contains(client: CmuxClient, request: Dict[str, Any], path: str, needle: str, timeout: float) -> None:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        response = execute_command(client, request)
        last = response
        text = get_path(response, path)
        if needle in text:
            return
        time.sleep(0.05)
    raise FixtureFailure(f"{needle!r} not found at {path}; last response: {last}")


def get_path(value: Any, path: str) -> Any:
    current = value
    for part in path.split("."):
        match = re.fullmatch(r"([A-Za-z0-9_-]+)(?:\[(\d+)\])?", part)
        if not match:
            raise FixtureFailure(f"bad JSON path segment {part!r}")
        key = match.group(1)
        if not isinstance(current, dict) or key not in current:
            raise FixtureFailure(f"path {path!r} missing key {key!r}")
        current = current[key]
        if match.group(2) is not None:
            index = int(match.group(2))
            if not isinstance(current, list) or index >= len(current):
                raise FixtureFailure(f"path {path!r} missing index {index}")
            current = current[index]
    return current


if __name__ == "__main__":
    raise SystemExit(main())
