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
from typing import Callable, Dict, Iterable, List, Optional, Tuple

from cmux import (
    AgentRecord,
    AgentState,
    AnyEvent,
    CmuxClient,
    CmuxConnectionError,
    CmuxError,
    EventStream,
    Id,
    LivePane,
    NotificationLevel,
    ProtocolError,
    TimeoutError as CmuxTimeoutError,
    Tree,
    UnknownEvent,
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
    scrollback_rows: int = 40

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
            "scrollback_rows": float(self.scrollback_rows),
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
class SurfaceContext:
    workspace: str
    screen: str
    pane: str
    title: str

    @property
    def label(self) -> str:
        parts = [self.workspace, self.screen, self.pane, self.title]
        return " / ".join(part for part in parts if part)


StreamMessage = Tuple[str, object]
AlertFingerprint = Tuple[str, int]
ClientFactory = Callable[..., CmuxClient]
EventSink = Callable[[str, AnyEvent], None]


class AgentWatchdog:
    """Owns one command client and two event subscriptions per connection."""

    def __init__(
        self,
        config: WatchdogConfig,
        *,
        client_factory: ClientFactory = CmuxClient,
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
        self._active_client: Optional[CmuxClient] = None
        self._alerted: Dict[Id, AlertFingerprint] = {}

    def request_stop(self) -> None:
        """Stop retry waits and unblock command or event reads."""

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
            except (CmuxConnectionError, CmuxTimeoutError, ProtocolError) as error:
                if self._stop.is_set():
                    return
                lifetime = self._monotonic() - connected_at
                if lifetime >= self.config.stable_connection_seconds:
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
        streams: List[EventStream] = []
        readers: List[threading.Thread] = []
        cycle_stop = threading.Event()
        messages: "queue.Queue[StreamMessage]" = queue.Queue()
        with self._active_lock:
            if self._stop.is_set():
                client.close()
                return
            self._active_client = client

        try:
            identity = client.identify()
            LOG.info(
                "connected to session=%s pid=%s protocol=%s",
                identity.session,
                identity.pid,
                identity.protocol,
            )
            client.set_client_info(name="python-agent-watchdog", kind="automation")

            subscriptions = (
                ("coarse", client.subscribe(tree_events="coarse")),
                ("deltas", client.subscribe_deltas()),
            )
            for name, stream in subscriptions:
                streams.append(stream)
                reader = threading.Thread(
                    target=self._pump_stream,
                    args=(name, stream, cycle_stop, messages),
                    name="cmux-watchdog-" + name,
                    daemon=True,
                )
                readers.append(reader)
                reader.start()

            self._scan(client)
            next_poll = self._monotonic() + self.config.poll_interval
            while not self._stop.is_set():
                timeout = max(0.0, next_poll - self._monotonic())
                try:
                    message_type, payload = messages.get(timeout=timeout)
                except queue.Empty:
                    self._scan(client)
                    next_poll = self._monotonic() + self.config.poll_interval
                    continue

                if message_type == "error":
                    assert isinstance(payload, BaseException)
                    raise payload

                source, event = payload
                assert isinstance(source, str)
                self._event_sink(source, event)
                if not isinstance(event, UnknownEvent):
                    self._scan(client)
                    next_poll = self._monotonic() + self.config.poll_interval
        finally:
            cycle_stop.set()
            for stream in streams:
                stream.close()
            client.close()
            for reader in readers:
                reader.join(timeout=1.0)
            with self._active_lock:
                if self._active_client is client:
                    self._active_client = None

    def _pump_stream(
        self,
        name: str,
        stream: EventStream,
        cycle_stop: threading.Event,
        messages: "queue.Queue[StreamMessage]",
    ) -> None:
        try:
            for event in stream:
                if cycle_stop.is_set() or self._stop.is_set():
                    return
                messages.put(("event", (name, event)))
            if not cycle_stop.is_set() and not self._stop.is_set():
                messages.put(
                    (
                        "error",
                        CmuxConnectionError(name + " event subscription closed"),
                    )
                )
        except BaseException as error:
            if not cycle_stop.is_set() and not self._stop.is_set():
                messages.put(("error", error))

    def _scan(self, client: CmuxClient) -> None:
        tree = client.list_workspaces()
        agents = client.list_agents().agents
        contexts = self._surface_contexts(tree)
        now_ms = self._wall_clock_ms()
        active_surfaces = set()

        for agent in agents:
            active_surfaces.add(agent.surface)
            condition = self._condition(agent, now_ms)
            if condition is None:
                self._alerted.pop(agent.surface, None)
                continue

            kind, age_ms = condition
            fingerprint = (kind, agent.updated_at_ms)
            if self._alerted.get(agent.surface) == fingerprint:
                continue

            excerpt = self._capture_excerpt(client, agent.surface)
            context = contexts.get(
                agent.surface,
                SurfaceContext("", "", "", "surface " + str(agent.surface)),
            )
            age = max(0, age_ms // 1000)
            session = agent.session or "unknown"
            client.notify(
                "Agent " + kind + ": " + context.label,
                (
                    "state="
                    + agent.state.value
                    + " session="
                    + session
                    + " surface="
                    + str(agent.surface)
                    + " unchanged_for="
                    + str(age)
                    + "s\n"
                    + excerpt
                ),
                level=NotificationLevel.WARNING,
                surface=agent.surface,
            )
            self._alerted[agent.surface] = fingerprint
            LOG.warning(
                "notified for %s agent on surface %s (%s)",
                kind,
                agent.surface,
                context.label,
            )

        for surface in set(self._alerted).difference(active_surfaces):
            del self._alerted[surface]

    def _condition(
        self, agent: AgentRecord, now_ms: int
    ) -> Optional[Tuple[str, int]]:
        age_ms = max(0, now_ms - agent.updated_at_ms)
        if agent.state is AgentState.BLOCKED:
            return ("blocked", age_ms)
        if (
            agent.state is AgentState.WORKING
            and age_ms >= int(self.config.stalled_after * 1000)
        ):
            return ("stalled", age_ms)
        return None

    def _capture_excerpt(self, client: CmuxClient, surface: Id) -> str:
        try:
            text = client.read_screen(surface).text
            if text.strip():
                return self._clip(text)
        except CmuxError as error:
            LOG.debug("read-screen failed for surface %s: %s", surface, error)

        try:
            first = client.read_scrollback(
                surface, start=0, count=self.config.scrollback_rows
            )
            start = max(0, first.total - self.config.scrollback_rows)
            rows = (
                first.rows
                if start == 0
                else client.read_scrollback(
                    surface,
                    start=start,
                    count=self.config.scrollback_rows,
                ).rows
            )
            text = "\n".join(
                "".join(run.text for run in row.runs).rstrip() for row in rows
            )
            if text.strip():
                return self._clip(text)
        except CmuxError as error:
            LOG.debug("read-scrollback failed for surface %s: %s", surface, error)

        return "(screen excerpt unavailable)"

    def _clip(self, text: str) -> str:
        normalized = "\n".join(line.rstrip() for line in text.strip().splitlines())
        if len(normalized) <= self.config.excerpt_chars:
            return normalized
        if self.config.excerpt_chars == 1:
            return "…"
        return "…" + normalized[-(self.config.excerpt_chars - 1) :]

    @staticmethod
    def _surface_contexts(tree: Tree) -> Dict[Id, SurfaceContext]:
        contexts: Dict[Id, SurfaceContext] = {}
        for workspace in tree.workspaces:
            for screen in workspace.screens:
                for pane in screen.panes:
                    if not isinstance(pane, LivePane):
                        continue
                    for tab in pane.tabs:
                        contexts[tab.surface] = SurfaceContext(
                            workspace=workspace.name,
                            screen=screen.name or "",
                            pane=pane.name or "",
                            title=tab.title,
                        )
        return contexts

    @staticmethod
    def _log_event(source: str, event: AnyEvent) -> None:
        if isinstance(event, UnknownEvent):
            LOG.info("ignored future event %r from %s", event.event, source)
        else:
            LOG.debug("received %s event from %s", event.event, source)


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
