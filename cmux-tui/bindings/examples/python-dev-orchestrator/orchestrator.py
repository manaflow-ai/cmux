#!/usr/bin/env python3
"""Create an isolated cmux workspace and run a small development pipeline."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, List, Optional, Sequence, Tuple

from cmux import (
    Client,
    CmuxError,
    Machine,
    MachineId,
    MutationIndeterminateError,
    MutationResult,
    Pane,
    ResourceError,
    Session,
    SessionDelta,
    SessionId,
    SessionSnapshotItem,
    Terminal,
    Unknown,
    Workspace,
    WorkspaceId,
    exact,
)
from cmux.options import (
    CreateScreenOptions,
    CreateTerminalOptions,
    CreateWorkspaceOptions,
    RunOptions,
    SplitPaneOptions,
    TerminalWaitOptions,
)


LOG = logging.getLogger("python-dev-orchestrator")
_RUN_ID = re.compile(r"^[A-Za-z0-9._-]+$")


class OrchestrationError(RuntimeError):
    """The requested environment could not be created safely."""


class SelectionError(OrchestrationError):
    """A resource selector was missing or ambiguous."""


@dataclass(frozen=True)
class Job:
    name: str
    argv: Tuple[str, ...]
    ready_pattern: str

    def __post_init__(self) -> None:
        if not self.name:
            raise ValueError("job name must be non-empty")
        if not self.argv or not self.argv[0]:
            raise ValueError("job argv must contain an executable")
        if not self.ready_pattern:
            raise ValueError("job ready_pattern must be non-empty")


def default_jobs() -> Tuple[Job, ...]:
    return (
        Job(
            "setup",
            (
                "/usr/bin/env",
                "python3",
                "-c",
                "print('CMUX_SETUP_READY')",
            ),
            "CMUX_SETUP_READY",
        ),
        Job(
            "build",
            (
                "/usr/bin/env",
                "python3",
                "-c",
                "print('CMUX_BUILD_OK')",
            ),
            "CMUX_BUILD_OK",
        ),
        Job(
            "tests",
            (
                "/usr/bin/env",
                "python3",
                "-c",
                "print('CMUX_TESTS_OK')",
            ),
            "CMUX_TESTS_OK",
        ),
    )


def load_jobs(path: str) -> Tuple[Job, ...]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read job plan {path}: {error}") from error
    if not isinstance(value, dict) or set(value) != {"jobs"}:
        raise ValueError("job plan must be an object containing only jobs")
    jobs = value["jobs"]
    if not isinstance(jobs, list):
        raise ValueError("job plan jobs must be an array")
    result: List[Job] = []
    for index, item in enumerate(jobs):
        if (
            not isinstance(item, dict)
            or set(item) != {"name", "argv", "ready_pattern"}
            or not isinstance(item["name"], str)
            or not isinstance(item["argv"], list)
            or not all(isinstance(value, str) for value in item["argv"])
            or not isinstance(item["ready_pattern"], str)
        ):
            raise ValueError(f"job plan item {index} has an invalid shape")
        result.append(
            Job(
                item["name"],
                tuple(item["argv"]),
                item["ready_pattern"],
            )
        )
    return tuple(result)


@dataclass(frozen=True)
class OrchestratorConfig:
    run_id: str
    session_name: str = "main"
    machine_id: Optional[MachineId] = None
    session_id: Optional[SessionId] = None
    workspace_name: Optional[str] = None
    workspace_id: Optional[WorkspaceId] = None
    cwd: Optional[str] = None
    request_timeout: float = 65.0
    event_ready_timeout: float = 5.0
    terminal_wait_timeout_ms: int = 60_000
    keep_workspace: bool = False
    jobs: Tuple[Job, ...] = field(default_factory=default_jobs)

    def __post_init__(self) -> None:
        if not _RUN_ID.fullmatch(self.run_id):
            raise ValueError(
                "run_id may contain only letters, digits, dot, underscore, and hyphen"
            )
        if not self.session_name and self.session_id is None:
            raise ValueError("session_name is required when session_id is absent")
        if self.workspace_name is not None and not self.workspace_name:
            raise ValueError("workspace_name must be non-empty")
        if self.request_timeout <= 0 or self.event_ready_timeout <= 0:
            raise ValueError("request and event timeouts must be positive")
        if self.terminal_wait_timeout_ms < 0:
            raise ValueError("terminal_wait_timeout_ms cannot be negative")
        if self.request_timeout * 1_000 <= self.terminal_wait_timeout_ms:
            raise ValueError(
                "request_timeout must exceed terminal_wait_timeout_ms because "
                "the SDK applies its request deadline to terminal.wait"
            )
        if len(self.jobs) != 3:
            raise ValueError("this example expects setup, build, and test jobs")

    @property
    def effective_workspace_name(self) -> str:
        return self.workspace_name or "python-ci-" + self.run_id


@dataclass(frozen=True)
class JobResult:
    name: str
    terminal_id: str
    output: str


@dataclass(frozen=True)
class OrchestrationResult:
    machine_id: str
    session_id: str
    workspace_id: str
    jobs: Tuple[JobResult, ...]
    event_kinds: Tuple[str, ...]
    replayed_actions: Tuple[str, ...]
    cleaned_up: bool

    def as_dict(self) -> dict:
        return {
            "machine_id": self.machine_id,
            "session_id": self.session_id,
            "workspace_id": self.workspace_id,
            "jobs": [
                {
                    "name": job.name,
                    "terminal_id": job.terminal_id,
                    "output": job.output,
                }
                for job in self.jobs
            ],
            "event_kinds": list(self.event_kinds),
            "replayed_actions": list(self.replayed_actions),
            "cleaned_up": self.cleaned_up,
        }


class EventJournal:
    """Consume the blocking typed stream without blocking orchestration calls."""

    def __init__(self, stream: Iterable[Any]) -> None:
        self._stream = stream
        self._typed_ready = threading.Event()
        self._lock = threading.Lock()
        self._kinds: List[str] = []
        self._failure: Optional[BaseException] = None
        self._thread = threading.Thread(
            target=self._consume,
            name="cmux-python-dev-events",
            daemon=True,
        )

    def start(self) -> None:
        self._thread.start()

    def wait_until_typed(self, timeout: float) -> None:
        if not self._typed_ready.wait(timeout):
            self.raise_if_failed()
            raise OrchestrationError(
                "session.events did not deliver a typed snapshot or delta "
                f"within {timeout:.1f}s"
            )
        self.raise_if_failed()

    def stop(self) -> None:
        cancel = getattr(self._stream, "cancel", None)
        cancel_failure: Optional[BaseException] = None
        try:
            if callable(cancel):
                cancel()
        except BaseException as error:
            cancel_failure = error
        self._thread.join(timeout=2.0)
        if self._thread.is_alive():
            raise OrchestrationError("session event reader did not stop after cancellation")
        if cancel_failure is not None:
            raise OrchestrationError(
                f"session event cancellation failed: {cancel_failure}"
            ) from cancel_failure
        self.raise_if_failed()

    def raise_if_failed(self) -> None:
        with self._lock:
            failure = self._failure
        if failure is not None:
            raise OrchestrationError(f"session event stream failed: {failure}") from failure

    @property
    def kinds(self) -> Tuple[str, ...]:
        with self._lock:
            return tuple(self._kinds)

    def _consume(self) -> None:
        try:
            for envelope in self._stream:
                event = envelope.item
                if isinstance(event, SessionSnapshotItem):
                    kind = "snapshot"
                    self._typed_ready.set()
                elif isinstance(event, SessionDelta):
                    kind = "delta"
                    self._typed_ready.set()
                elif isinstance(event, Unknown):
                    kind = "unknown:" + event.kind
                else:
                    kind = "unexpected:" + type(event).__name__
                with self._lock:
                    self._kinds.append(kind)
        except BaseException as error:
            with self._lock:
                self._failure = error
            self._typed_ready.set()


def _require_snapshot(handle: Any, label: str) -> Any:
    snapshot = handle.snapshot
    if snapshot is None:
        raise OrchestrationError(f"{label} did not include a snapshot")
    return snapshot


def _format_session_candidates(candidates: Sequence[Tuple[Machine, Session]]) -> str:
    return ", ".join(
        f"session={session.id} machine={machine.id}"
        for machine, session in candidates
    )


def select_session(
    client: Client,
    *,
    session_name: str,
    machine_id: Optional[MachineId] = None,
    session_id: Optional[SessionId] = None,
) -> Tuple[Machine, Session]:
    """Resolve exact snapshots first, then operate through their typed IDs."""

    machines = client.list_machines()
    if machine_id is not None:
        machines = [machine for machine in machines if machine.id == machine_id]
        if not machines:
            raise SelectionError(f"machine ID {machine_id} was not found")

    candidates: List[Tuple[Machine, Session]] = []
    for machine in machines:
        for session in machine.list_sessions():
            snapshot = _require_snapshot(session, "listed session")
            if session_id is not None:
                if session.id == session_id:
                    candidates.append((machine, session))
            elif snapshot.name == session_name:
                candidates.append((machine, session))

    selector = f"ID {session_id}" if session_id is not None else f"name {session_name!r}"
    if not candidates:
        raise SelectionError(f"no session matched {selector}")
    if len(candidates) > 1:
        raise SelectionError(
            f"session {selector} is ambiguous: "
            + _format_session_candidates(candidates)
            + "; pass --session-id and, if needed, --machine-id"
        )
    return candidates[0]


def select_workspace(
    session: Session,
    *,
    workspace_name: str,
    workspace_id: Optional[WorkspaceId] = None,
    allow_missing: bool = False,
) -> Optional[Workspace]:
    """Resolve an exact workspace name without relying on a name selector."""

    workspaces = session.list_workspaces()
    if workspace_id is not None:
        matches = [
            workspace for workspace in workspaces if workspace.id == workspace_id
        ]
        selector = f"ID {workspace_id}"
    else:
        matches = [
            workspace
            for workspace in workspaces
            if _require_snapshot(workspace, "listed workspace").name == workspace_name
        ]
        selector = f"name {workspace_name!r}"

    if not matches:
        if allow_missing:
            return None
        raise SelectionError(f"no workspace matched {selector}")
    if len(matches) > 1:
        ids = ", ".join(str(workspace.id) for workspace in matches)
        raise SelectionError(
            f"workspace {selector} is ambiguous: {ids}; pass --workspace-id"
        )
    return matches[0]


def mutation_key(run_id: str, action: str, attempt: int = 0) -> str:
    material = f"{run_id}\0{action}\0{attempt}".encode("utf-8")
    digest = hashlib.sha256(material).hexdigest()[:32]
    label = re.sub(r"[^A-Za-z0-9._-]", "-", action)[:40]
    return f"python-dev-orchestrator:{label}:{digest}"


def _accept_receipt(
    action: str,
    receipt: MutationResult[Any],
    replayed_actions: List[str],
) -> str:
    if receipt.replayed:
        replayed_actions.append(action)
        LOG.info("%s replayed an earlier mutation receipt", action)
    return receipt.revision


def _created_terminal(receipt: MutationResult[Any], action: str) -> Tuple[Pane, Terminal]:
    created = receipt.value
    if created.pane is None or created.terminal is None:
        raise OrchestrationError(
            f"{action} did not return the created pane and terminal handles"
        )
    return created.pane, created.terminal


def _refresh_session_revision(session: Session) -> str:
    return session.refresh().revision


def _create_empty_workspace(
    session: Session,
    config: OrchestratorConfig,
    replayed_actions: List[str],
) -> Tuple[Workspace, str]:
    name = config.effective_workspace_name
    selected = select_workspace(
        session,
        workspace_name=name,
        workspace_id=config.workspace_id,
        allow_missing=True,
    )
    if selected is not None:
        if config.workspace_id is None:
            raise SelectionError(
                f"workspace name {name!r} already exists as {selected.id}; "
                "use a new --run-id or pass that exact --workspace-id to resume ownership"
            )
        return selected, _refresh_session_revision(session)
    if config.workspace_id is not None:
        raise SelectionError(f"workspace ID {config.workspace_id} was not found")

    options = CreateWorkspaceOptions(name=name, initial_content="empty")
    last_error: Optional[MutationIndeterminateError] = None
    for attempt in range(2):
        action = "workspace.create" if attempt == 0 else "workspace.create.recovery"
        try:
            receipt = session.create_workspace(
                options,
                idempotency_key=mutation_key(config.run_id, "workspace.create", attempt),
            )
        except MutationIndeterminateError as error:
            last_error = error
            recovered = select_workspace(
                session,
                workspace_name=name,
                allow_missing=True,
            )
            if recovered is not None:
                LOG.warning(
                    "workspace.create was indeterminate; unique-name inspection "
                    "found %s",
                    recovered.id,
                )
                return recovered, _refresh_session_revision(session)
            continue

        revision = _accept_receipt(action, receipt, replayed_actions)
        workspace = receipt.value.workspace
        snapshot = workspace.refresh()
        if snapshot.name != name:
            raise OrchestrationError(
                "workspace.create returned a workspace with an unexpected name"
            )
        return workspace, revision

    assert last_error is not None
    raise OrchestrationError(
        "workspace.create remained indeterminate after state inspection and "
        "one new-key recovery attempt"
    ) from last_error


def _receipted_create(
    action: str,
    run_id: str,
    revision: str,
    replayed_actions: List[str],
    mutation: Callable[[str, str], MutationResult[Any]],
) -> Tuple[MutationResult[Any], str]:
    key = mutation_key(run_id, action)
    try:
        receipt = mutation(key, revision)
    except MutationIndeterminateError as error:
        raise OrchestrationError(
            f"{action} is indeterminate under key {key}; automatic retry is "
            "refused because this create cannot reserve or query a caller-owned "
            "public resource ID"
        ) from error
    return receipt, _accept_receipt(action, receipt, replayed_actions)


def _workspace_still_exists(session: Session, workspace_id: WorkspaceId) -> bool:
    return (
        select_workspace(
            session,
            workspace_name="ignored-for-id-selection",
            workspace_id=workspace_id,
            allow_missing=True,
        )
        is not None
    )


def _cleanup_workspace(
    session: Session,
    workspace: Workspace,
    run_id: str,
    revision: str,
    replayed_actions: List[str],
) -> bool:
    workspace_id = workspace.id
    if workspace_id is None:
        raise OrchestrationError("cannot clean up a workspace without an ID")

    last_error: Optional[BaseException] = None
    for attempt in range(3):
        try:
            receipt = workspace.close(
                idempotency_key=mutation_key(run_id, "workspace.close", attempt),
                expected_revision=revision,
            )
        except MutationIndeterminateError as error:
            last_error = error
            if not _workspace_still_exists(session, workspace_id):
                LOG.warning(
                    "workspace.close was indeterminate, but ID inspection "
                    "confirmed deletion"
                )
                return True
            revision = _refresh_session_revision(session)
            continue
        except ResourceError as error:
            if error.code != "revision.conflict":
                raise
            last_error = error
            if not _workspace_still_exists(session, workspace_id):
                return True
            revision = _refresh_session_revision(session)
            continue

        _accept_receipt(
            "workspace.close"
            if attempt == 0
            else f"workspace.close.recovery-{attempt}",
            receipt,
            replayed_actions,
        )
        return True

    assert last_error is not None
    if not _workspace_still_exists(session, workspace_id):
        return True
    raise OrchestrationError(
        f"workspace {workspace_id} still exists after inspected close recovery"
    ) from last_error


def _wait_for_job(terminal: Terminal, job: Job, timeout_ms: int) -> JobResult:
    terminal_id = terminal.id
    if terminal_id is None:
        raise OrchestrationError(f"job {job.name} returned a terminal without an ID")
    document = terminal.wait(
        TerminalWaitOptions(
            pattern=job.ready_pattern,
            timeout_ms=timeout_ms,
        )
    )
    matched = document.fields.get("matched")
    output = document.fields.get("text")
    if matched is not True or not isinstance(output, str):
        excerpt = output[-400:] if isinstance(output, str) else repr(output)
        raise OrchestrationError(
            f"job {job.name} did not produce {job.ready_pattern!r}: {excerpt}"
        )
    return JobResult(job.name, str(terminal_id), output)


def orchestrate(client: Client, config: OrchestratorConfig) -> OrchestrationResult:
    machine, session = select_session(
        client,
        session_name=config.session_name,
        machine_id=config.machine_id,
        session_id=config.session_id,
    )
    machine_id = machine.id
    session_id = session.id
    if machine_id is None or session_id is None:
        raise OrchestrationError("selected resources did not include public IDs")

    stream = session.events()
    journal = EventJournal(stream)
    journal.start()
    journal.wait_until_typed(config.event_ready_timeout)

    workspace: Optional[Workspace] = None
    revision = "0"
    replayed_actions: List[str] = []
    results: List[JobResult] = []
    cleaned_up = False
    failure: Optional[BaseException] = None

    try:
        workspace, revision = _create_empty_workspace(
            session,
            config,
            replayed_actions,
        )

        screen_receipt, revision = _receipted_create(
            "screen.create",
            config.run_id,
            revision,
            replayed_actions,
            lambda key, expected: workspace.create_screen(
                CreateScreenOptions(name="CI " + config.run_id),
                idempotency_key=key,
                expected_revision=expected,
            ),
        )
        primary_pane, _bootstrap_terminal = _created_terminal(
            screen_receipt,
            "screen.create",
        )

        split_receipt, revision = _receipted_create(
            "pane.split",
            config.run_id,
            revision,
            replayed_actions,
            lambda key, expected: primary_pane.split(
                SplitPaneOptions(
                    direction="right",
                    ratio=0.5,
                    cwd=config.cwd,
                    columns=100,
                    rows=30,
                ),
                idempotency_key=key,
                expected_revision=expected,
            ),
        )
        secondary_pane, _split_terminal = _created_terminal(
            split_receipt,
            "pane.split",
        )

        shell_receipt, revision = _receipted_create(
            "tab.create_terminal",
            config.run_id,
            revision,
            replayed_actions,
            lambda key, expected: primary_pane.create_terminal_tab(
                CreateTerminalOptions(
                    cwd=config.cwd,
                    name="debug-shell",
                    columns=100,
                    rows=30,
                ),
                idempotency_key=key,
                expected_revision=expected,
            ),
        )
        if shell_receipt.value.tab is None or shell_receipt.value.terminal is None:
            raise OrchestrationError(
                "tab.create_terminal did not return tab and terminal handles"
            )

        lanes = (primary_pane, secondary_pane, primary_pane)
        for job, lane in zip(config.jobs, lanes):
            action = "pane.run." + job.name
            run_receipt, revision = _receipted_create(
                action,
                config.run_id,
                revision,
                replayed_actions,
                lambda key, expected, job=job, lane=lane: lane.run(
                    RunOptions(
                        exact(job.argv, cwd=config.cwd),
                        name=job.name,
                        columns=100,
                        rows=30,
                    ),
                    idempotency_key=key,
                    expected_revision=expected,
                ),
            )
            _job_pane, job_terminal = _created_terminal(run_receipt, action)
            results.append(
                _wait_for_job(
                    job_terminal,
                    job,
                    config.terminal_wait_timeout_ms,
                )
            )
            journal.raise_if_failed()
    except BaseException as error:
        failure = error
    finally:
        cleanup_failure: Optional[BaseException] = None
        if workspace is not None and not config.keep_workspace:
            try:
                cleaned_up = _cleanup_workspace(
                    session,
                    workspace,
                    config.run_id,
                    revision,
                    replayed_actions,
                )
            except BaseException as error:
                cleanup_failure = error
        try:
            journal.stop()
        except BaseException as error:
            if cleanup_failure is None:
                cleanup_failure = error

        if failure is not None:
            if cleanup_failure is not None:
                raise OrchestrationError(
                    f"orchestration failed ({failure}); cleanup also failed "
                    f"({cleanup_failure})"
                ) from failure
            raise failure
        if cleanup_failure is not None:
            raise cleanup_failure

    assert workspace is not None
    workspace_id = workspace.id
    if workspace_id is None:
        raise OrchestrationError("created workspace did not include an ID")
    return OrchestrationResult(
        str(machine_id),
        str(session_id),
        str(workspace_id),
        tuple(results),
        journal.kinds,
        tuple(replayed_actions),
        cleaned_up,
    )


def _typed_id(value: Optional[str], constructor: Callable[[str], Any]) -> Any:
    if value is None:
        return None
    return constructor(value)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", help="explicit cmux.protocol/1 Unix socket")
    parser.add_argument(
        "--socket-session",
        default="main",
        help="named socket session used only when --socket is absent",
    )
    parser.add_argument("--run-id", required=True, help="unique CI or developer run")
    parser.add_argument("--machine-id")
    parser.add_argument("--session-id")
    parser.add_argument("--session-name", default="main")
    parser.add_argument("--workspace-id")
    parser.add_argument("--workspace-name")
    parser.add_argument("--cwd")
    parser.add_argument(
        "--plan",
        help="JSON file containing exactly three exact-argv jobs",
    )
    parser.add_argument("--request-timeout", type=float, default=65.0)
    parser.add_argument("--event-ready-timeout", type=float, default=5.0)
    parser.add_argument("--terminal-wait-timeout-ms", type=int, default=60_000)
    parser.add_argument("--keep-workspace", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s %(message)s",
    )
    try:
        config = OrchestratorConfig(
            run_id=args.run_id,
            session_name=args.session_name,
            machine_id=_typed_id(args.machine_id, MachineId),
            session_id=_typed_id(args.session_id, SessionId),
            workspace_name=args.workspace_name,
            workspace_id=_typed_id(args.workspace_id, WorkspaceId),
            cwd=args.cwd,
            request_timeout=args.request_timeout,
            event_ready_timeout=args.event_ready_timeout,
            terminal_wait_timeout_ms=args.terminal_wait_timeout_ms,
            keep_workspace=args.keep_workspace,
            jobs=load_jobs(args.plan) if args.plan else default_jobs(),
        )
        with Client(
            socket_path=args.socket,
            session=args.socket_session,
            timeout=config.request_timeout,
        ) as client:
            result = orchestrate(client, config)
    except (CmuxError, OrchestrationError, ValueError) as error:
        print(f"python-dev-orchestrator: {error}", file=sys.stderr)
        return 2

    print(json.dumps(result.as_dict(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
