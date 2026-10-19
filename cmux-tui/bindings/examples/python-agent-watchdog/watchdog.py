#!/usr/bin/env python3
"""Watch cmux agents and notify when one is blocked or stops reporting progress."""

from __future__ import annotations

import argparse
import logging
import queue
import signal
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, Iterator, Optional, Protocol, Tuple

from cmux import (
    AgentId,
    AgentSnapshot,
    Client,
    CmuxConnectionError,
    CmuxError,
    NotificationOptions,
    ProtocolError,
    ResourceSnapshot,
    Selector,
    Session,
    SessionEvent,
    StreamError,
    TerminalHistoryResult,
    TerminalHistoryOptions,
    TerminalId,
    TimeoutError as CmuxTimeoutError,
    Unknown,
)


LOG = logging.getLogger("cmux-agent-watchdog")


@dataclass(frozen=True)
class WatchdogConfig:
    session: str = "main"
    socket_path: Optional[str] = None
    poll_interval: float = 5.0
    stalled_after: float = 300.0
    timeout: float = 10.0
    reconnect_initial: float = 0.5
    reconnect_max: float = 15.0
    reconnect_multiplier: float = 2.0
    stable_connection_seconds: float = 30.0
    excerpt_chars: int = 800
    history_rows: int = 40

    def __post_init__(self) -> None:
        positive = {
            "poll_interval": self.poll_interval,
            "stalled_after": self.stalled_after,
            "timeout": self.timeout,
            "reconnect_initial": self.reconnect_initial,
            "reconnect_max": self.reconnect_max,
            "reconnect_multiplier": self.reconnect_multiplier,
            "stable_connection_seconds": self.stable_connection_seconds,
            "excerpt_chars": float(self.excerpt_chars),
            "history_rows": float(self.history_rows),
        }
        invalid = [name for name, value in positive.items() if value <= 0]
        if invalid:
            raise ValueError(
                "watchdog settings must be positive: " + ", ".join(sorted(invalid))
            )
        if self.reconnect_initial > self.reconnect_max:
            raise ValueError("reconnect_initial cannot exceed reconnect_max")
        if self.reconnect_multiplier < 1:
            raise ValueError("reconnect_multiplier cannot be less than 1")


@dataclass(frozen=True)
class TerminalContext:
    workspace: str
    screen: str
    pane: str
    title: str

    @property
    def label(self) -> str:
        return " / ".join(
            part for part in (self.workspace, self.screen, self.pane, self.title) if part
        )


StreamMessage = Tuple[str, object]
AlertFingerprint = Tuple[str, str]
ClientFactory = Callable[..., Client]
EventSink = Callable[[SessionEvent], None]


class EventStream(Protocol, Iterator[object]):
    def close(self) -> None:
        ...


class AgentWatchdog:
    """Own one resource client and one typed session event stream per connection."""

    def __init__(
        self,
        config: WatchdogConfig,
        *,
        client_factory: ClientFactory = Client,
        event_sink: Optional[EventSink] = None,
        wall_clock_ms: Optional[Callable[[], int]] = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.config = config
        self._client_factory = client_factory
        self._event_sink = event_sink or self._log_event
        self._wall_clock_ms = wall_clock_ms or (lambda: int(time.time() * 1000))
        self._monotonic = monotonic
        self._stop = threading.Event()
        self._active_lock = threading.Lock()
        self._active_client: Optional[Client] = None
        self._alerted: Dict[AgentId, AlertFingerprint] = {}

    def request_stop(self) -> None:
        """Stop retry waits and unblock resource reads."""

        self._stop.set()
        with self._active_lock:
            client = self._active_client
        if client is not None:
            client.close()

    def run(self) -> None:
        """Run until request_stop() is called."""

        delay = self.config.reconnect_initial
        while not self._stop.is_set():
            connected_at = self._monotonic()
            try:
                self._run_connected()
                return
            except (
                CmuxConnectionError,
                CmuxTimeoutError,
                ProtocolError,
                StreamError,
            ) as error:
                if self._stop.is_set():
                    return
                if self._monotonic() - connected_at >= self.config.stable_connection_seconds:
                    delay = self.config.reconnect_initial
                LOG.warning(
                    "connection lost (%s); reconnecting in %.2fs", error, delay
                )
                if self._stop.wait(delay):
                    return
                delay = min(
                    self.config.reconnect_max,
                    delay * self.config.reconnect_multiplier,
                )

    def _run_connected(self) -> None:
        client = self._client_factory(
            socket_path=self.config.socket_path,
            session=self.config.session,
            timeout=self.config.timeout,
        )
        session = client.session(Selector.name(self.config.session))
        cycle_stop = threading.Event()
        messages: "queue.Queue[StreamMessage]" = queue.Queue()
        stream: Optional[EventStream] = None
        reader: Optional[threading.Thread] = None
        with self._active_lock:
            if self._stop.is_set():
                client.close()
                return
            self._active_client = client

        try:
            stream = session.events()
            reader = threading.Thread(
                target=self._pump_stream,
                args=(stream, cycle_stop, messages),
                name="cmux-watchdog-events",
                daemon=True,
            )
            reader.start()
            LOG.info("connected to session=%s", self.config.session)

            self._scan(session)
            next_poll = self._monotonic() + self.config.poll_interval
            while not self._stop.is_set():
                timeout = max(0.0, next_poll - self._monotonic())
                try:
                    message_type, payload = messages.get(timeout=timeout)
                except queue.Empty:
                    self._scan(session)
                    next_poll = self._monotonic() + self.config.poll_interval
                    continue

                if message_type == "error":
                    assert isinstance(payload, BaseException)
                    raise payload

                event = payload
                self._event_sink(event)  # type: ignore[arg-type]
                if not isinstance(event, Unknown):
                    self._scan(session)
                    next_poll = self._monotonic() + self.config.poll_interval
        finally:
            cycle_stop.set()
            if stream is not None:
                stream.close()
            client.close()
            if reader is not None:
                reader.join(timeout=1.0)
            with self._active_lock:
                if self._active_client is client:
                    self._active_client = None

    def _pump_stream(
        self,
        stream: EventStream,
        cycle_stop: threading.Event,
        messages: "queue.Queue[StreamMessage]",
    ) -> None:
        try:
            for item in stream:
                if cycle_stop.is_set() or self._stop.is_set():
                    return
                messages.put(("event", item.item))
            if not cycle_stop.is_set() and not self._stop.is_set():
                messages.put(
                    ("error", CmuxConnectionError("session event stream closed"))
                )
        except BaseException as error:
            if not cycle_stop.is_set() and not self._stop.is_set():
                messages.put(("error", error))

    def _scan(self, session: Session) -> None:
        snapshot = session.full_snapshot()
        contexts = self._terminal_contexts(snapshot)
        now_ms = self._wall_clock_ms()
        active_agents = set()

        for agent in snapshot.agents:
            active_agents.add(agent.id)
            condition = self._condition(agent, now_ms)
            if condition is None:
                self._alerted.pop(agent.id, None)
                continue

            kind, age_ms = condition
            fingerprint = (kind, agent.updated_at_ms)
            if self._alerted.get(agent.id) == fingerprint:
                continue

            excerpt = self._capture_excerpt(session, agent.terminal_id)
            context = contexts.get(
                agent.terminal_id,
                TerminalContext("", "", "", str(agent.terminal_id)),
            )
            session_name = agent.source_session or "unknown"
            session.create_notification(
                NotificationOptions(
                    title="Agent " + kind + ": " + context.label,
                    body=(
                        "state="
                        + agent.state
                        + " session="
                        + session_name
                        + " terminal="
                        + str(agent.terminal_id)
                        + " unchanged_for="
                        + str(max(0, age_ms // 1000))
                        + "s\n"
                        + excerpt
                    ),
                    level="warning",
                    terminal_id=agent.terminal_id,
                )
            )
            self._alerted[agent.id] = fingerprint
            LOG.warning(
                "notified for %s agent %s (%s)", kind, agent.id, context.label
            )

        for agent_id in set(self._alerted).difference(active_agents):
            del self._alerted[agent_id]

    def _condition(
        self, agent: AgentSnapshot, now_ms: int
    ) -> Optional[Tuple[str, int]]:
        age_ms = max(0, now_ms - int(agent.updated_at_ms))
        if agent.state == "blocked":
            return ("blocked", age_ms)
        if (
            agent.state == "working"
            and age_ms >= int(self.config.stalled_after * 1000)
        ):
            return ("stalled", age_ms)
        return None

    def _capture_excerpt(self, session: Session, terminal_id: TerminalId) -> str:
        terminal = session.terminal(terminal_id)
        try:
            text = terminal.read_screen().text
            if text.strip():
                return self._clip(text)
        except CmuxError as error:
            LOG.debug("screen read failed for terminal %s: %s", terminal_id, error)

        try:
            history = terminal.read_history(
                TerminalHistoryOptions(limit=self.config.history_rows)
            )
            text = self._history_text(history)
            if text.strip():
                return self._clip(text)
        except CmuxError as error:
            LOG.debug("history read failed for terminal %s: %s", terminal_id, error)

        return "(screen excerpt unavailable)"

    @staticmethod
    def _history_text(history: TerminalHistoryResult) -> str:
        return "\n".join(
            "".join(run.text for run in row.runs)
            for row in history.rows
        )

    def _clip(self, text: str) -> str:
        normalized = "\n".join(line.rstrip() for line in text.strip().splitlines())
        if len(normalized) <= self.config.excerpt_chars:
            return normalized
        if self.config.excerpt_chars == 1:
            return "…"
        return "…" + normalized[-(self.config.excerpt_chars - 1) :]

    @staticmethod
    def _terminal_contexts(
        snapshot: ResourceSnapshot,
    ) -> Dict[TerminalId, TerminalContext]:
        workspaces = {item.id: item for item in snapshot.workspaces}
        screens = {item.id: item for item in snapshot.screens}
        panes = {item.id: item for item in snapshot.panes}
        tabs = {item.id: item for item in snapshot.tabs}
        contexts: Dict[TerminalId, TerminalContext] = {}
        for terminal in snapshot.terminals:
            placements = [tabs[item] for item in terminal.tab_ids if item in tabs]
            tab = next((item for item in placements if item.focused), None)
            if tab is None:
                tab = next(iter(placements), None)
            if tab is None:
                continue
            pane = panes.get(tab.pane_id)
            screen = screens.get(pane.screen_id) if pane is not None else None
            workspace = (
                workspaces.get(screen.workspace_id) if screen is not None else None
            )
            contexts[terminal.id] = TerminalContext(
                workspace=workspace.name if workspace is not None else "",
                screen=(screen.name or "") if screen is not None else "",
                pane=(pane.name or "") if pane is not None else "",
                title=terminal.title,
            )
        return contexts

    @staticmethod
    def _log_event(event: SessionEvent) -> None:
        if isinstance(event, Unknown):
            LOG.info("ignored future session event %r", event.kind)
        else:
            LOG.debug("received %s session event", event.kind)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Notify when a cmux agent is blocked or stops reporting progress."
    )
    parser.add_argument("--session", default="main")
    parser.add_argument("--socket", dest="socket_path")
    parser.add_argument("--poll-interval", type=float, default=5.0)
    parser.add_argument("--stalled-after", type=float, default=300.0)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--reconnect-initial", type=float, default=0.5)
    parser.add_argument("--reconnect-max", type=float, default=15.0)
    parser.add_argument(
        "--log-level",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        default="INFO",
    )
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = _parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    watchdog = AgentWatchdog(
        WatchdogConfig(
            session=args.session,
            socket_path=args.socket_path,
            poll_interval=args.poll_interval,
            stalled_after=args.stalled_after,
            timeout=args.timeout,
            reconnect_initial=args.reconnect_initial,
            reconnect_max=args.reconnect_max,
        )
    )

    def stop(_signum: int, _frame: object) -> None:
        watchdog.request_stop()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        watchdog.run()
    except KeyboardInterrupt:
        watchdog.request_stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
