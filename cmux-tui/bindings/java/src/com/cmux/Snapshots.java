package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Immutable protocol-v2 resource snapshots. */
public final class Snapshots {
    public record MachineSnapshot(
        Ids.MachineId id,
        String name,
        String origin,
        String status,
        boolean connectable,
        boolean deleted,
        boolean recoverable,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public MachineSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(name, "name");
            oneOf(origin, "origin", "local");
            oneOf(
                status,
                "status",
                "running",
                "connecting",
                "sleeping",
                "stopped",
                "unavailable"
            );
            extra = copy(extra);
        }
    }

    public record SessionSnapshot(
        Ids.SessionId id,
        Ids.MachineId machineId,
        Optional<String> name,
        String generation,
        Decimal revision,
        boolean connected,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public SessionSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(machineId, "machineId");
            name = opt(name);
            Objects.requireNonNull(generation, "generation");
            Objects.requireNonNull(revision, "revision");
            extra = copy(extra);
        }
    }

    public record WorkspaceSnapshot(
        Ids.WorkspaceId id,
        Ids.SessionId sessionId,
        String name,
        long index,
        boolean focused,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public WorkspaceSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            Objects.requireNonNull(name, "name");
            nonnegative(index, "index");
            extra = copy(extra);
        }
    }

    public record ScreenSnapshot(
        Ids.ScreenId id,
        Ids.WorkspaceId workspaceId,
        Optional<String> name,
        long index,
        boolean focused,
        Layout.Document layout,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public ScreenSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(workspaceId, "workspaceId");
            name = opt(name);
            nonnegative(index, "index");
            Objects.requireNonNull(layout, "layout");
            extra = copy(extra);
        }
    }

    public record PaneSnapshot(
        Ids.PaneId id,
        Ids.ScreenId screenId,
        Optional<String> name,
        boolean focused,
        boolean zoomed,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public PaneSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(screenId, "screenId");
            name = opt(name);
            extra = copy(extra);
        }
    }

    public record TabSnapshot(
        Ids.TabId id,
        Ids.PaneId paneId,
        Optional<String> name,
        long index,
        boolean focused,
        String contentKind,
        Ids.Id contentId,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public TabSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(paneId, "paneId");
            name = opt(name);
            nonnegative(index, "index");
            oneOf(contentKind, "contentKind", "terminal", "browser");
            Objects.requireNonNull(contentId, "contentId");
            if (contentKind.equals("terminal") &&
                    !(contentId instanceof Ids.TerminalId)) {
                throw new IllegalArgumentException(
                    "terminal tab requires a terminal content ID"
                );
            }
            if (contentKind.equals("browser") &&
                    !(contentId instanceof Ids.BrowserId)) {
                throw new IllegalArgumentException(
                    "browser tab requires a browser content ID"
                );
            }
            extra = copy(extra);
        }
    }

    public enum TerminalLifecycle {
        LAUNCHING,
        RUNNING,
        EXITED
    }

    public record TerminalExit(
        Results.TerminalExitOutcome outcome,
        Decimal exitedAt,
        Decimal revision
    ) {
        public TerminalExit {
            Objects.requireNonNull(outcome, "outcome");
            Objects.requireNonNull(exitedAt, "exitedAt");
            Objects.requireNonNull(revision, "revision");
        }
    }

    public record TerminalSnapshot(
        Ids.TerminalId id,
        List<Ids.TabId> tabIds,
        String title,
        Optional<String> cwd,
        int cols,
        int rows,
        boolean running,
        TerminalLifecycle lifecycle,
        Optional<TerminalExit> exit,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public TerminalSnapshot {
            Objects.requireNonNull(id, "id");
            tabIds = List.copyOf(tabIds);
            Objects.requireNonNull(title, "title");
            cwd = opt(cwd);
            positiveUint16(cols, "cols");
            positiveUint16(rows, "rows");
            Objects.requireNonNull(lifecycle, "lifecycle");
            exit = opt(exit);
            if (running != (lifecycle == TerminalLifecycle.RUNNING)) {
                throw new IllegalArgumentException(
                    "running must match the running lifecycle"
                );
            }
            if (exit.isPresent() !=
                    (lifecycle == TerminalLifecycle.EXITED)) {
                throw new IllegalArgumentException(
                    "exit must be present exactly for the exited lifecycle"
                );
            }
            extra = copy(extra);
        }
    }

    public record Size(int cols, int rows) {
        public Size {
            positiveUint16(cols, "cols");
            positiveUint16(rows, "rows");
        }
    }

    public record PixelSize(long widthPx, long heightPx) {
        public PixelSize {
            positiveUint32(widthPx, "widthPx");
            positiveUint32(heightPx, "heightPx");
        }
    }

    public record BrowserSnapshot(
        Ids.BrowserId id,
        Ids.TabId tabId,
        String url,
        String title,
        boolean loading,
        String source,
        String status,
        Optional<String> error,
        boolean framesStalled,
        Size size,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public BrowserSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(tabId, "tabId");
            Objects.requireNonNull(url, "url");
            Objects.requireNonNull(title, "title");
            oneOf(source, "source", "external", "launched");
            oneOf(status, "status", "starting", "live", "failed");
            error = opt(error);
            Objects.requireNonNull(size, "size");
            extra = copy(extra);
        }
    }

    public record ClientSnapshot(
        Ids.ConnectedClientId id,
        Ids.SessionId sessionId,
        Optional<String> name,
        Optional<String> clientKind,
        String transport,
        Decimal connectedSeconds,
        List<Ids.TerminalId> attachedTerminalIds,
        List<ClientTerminalSize> sizes,
        boolean self,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public ClientSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            name = opt(name);
            clientKind = opt(clientKind);
            oneOf(transport, "transport", "unix", "websocket");
            Objects.requireNonNull(connectedSeconds, "connectedSeconds");
            attachedTerminalIds = List.copyOf(attachedTerminalIds);
            sizes = List.copyOf(sizes);
            extra = copy(extra);
        }
    }

    public record ClientTerminalSize(
        Ids.TerminalId terminalId,
        Optional<Integer> columns,
        Optional<Integer> rows,
        boolean participating
    ) {
        public ClientTerminalSize {
            Objects.requireNonNull(terminalId, "terminalId");
            columns = opt(columns);
            rows = opt(rows);
            columns.ifPresent(value -> positiveUint16(value, "columns"));
            rows.ifPresent(value -> positiveUint16(value, "rows"));
            if (columns.isPresent() != rows.isPresent()) {
                throw new IllegalArgumentException(
                    "client terminal columns and rows must both be present or both be absent"
                );
            }
        }
    }

    public record NotificationSnapshot(
        Ids.NotificationId id,
        Ids.SessionId sessionId,
        String title,
        String body,
        String level,
        Optional<Ids.TerminalId> terminalId,
        Decimal createdAtMS,
        boolean unread,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public NotificationSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            Objects.requireNonNull(title, "title");
            Objects.requireNonNull(body, "body");
            oneOf(level, "level", "info", "warning", "error");
            terminalId = opt(terminalId);
            Objects.requireNonNull(createdAtMS, "createdAtMS");
            extra = copy(extra);
        }
    }

    public record AgentSnapshot(
        Ids.AgentId id,
        Ids.SessionId sessionId,
        Ids.TerminalId terminalId,
        String state,
        String source,
        Decimal updatedAtMS,
        Optional<String> sourceSession,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public AgentSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            Objects.requireNonNull(terminalId, "terminalId");
            oneOf(state, "state", "working", "blocked", "idle", "done", "unknown");
            oneOf(source, "source", "hook", "socket", "detected");
            Objects.requireNonNull(updatedAtMS, "updatedAtMS");
            sourceSession = opt(sourceSession);
            extra = copy(extra);
        }
    }

    public record PairingRequestSnapshot(
        Ids.PairingRequestId id,
        Ids.SessionId sessionId,
        String peer,
        Secret code,
        Decimal expiresInSeconds,
        String status,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public PairingRequestSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            Objects.requireNonNull(peer, "peer");
            Objects.requireNonNull(code, "code");
            Objects.requireNonNull(expiresInSeconds, "expiresInSeconds");
            oneOf(status, "status", "pending", "accepted", "rejected");
            extra = copy(extra);
        }
    }

    public record FrontendProjectionSnapshot(
        Ids.ProjectionId id,
        Ids.SessionId sessionId,
        String frontendId,
        String windowId,
        String generation,
        JsonValue projection,
        Decimal projectionRevision,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public FrontendProjectionSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            Objects.requireNonNull(frontendId, "frontendId");
            Objects.requireNonNull(windowId, "windowId");
            Objects.requireNonNull(generation, "generation");
            Objects.requireNonNull(projection, "projection");
            Objects.requireNonNull(projectionRevision, "projectionRevision");
            extra = copy(extra);
        }
    }

    public record SidebarViewSnapshot(
        Ids.SidebarViewId id,
        Ids.SessionId sessionId,
        int columns,
        int rows,
        boolean running,
        Map<String, Object> extra
    ) implements ResourceEntitySnapshot {
        public SidebarViewSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            positiveUint16(columns, "columns");
            positiveUint16(rows, "rows");
            extra = copy(extra);
        }
    }

    private Snapshots() {}

    private static <T> Optional<T> opt(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }

    private static Map<String, Object> copy(Map<String, Object> value) {
        return value == null
            ? Map.of()
            : JsonValue.immutableObject(value, "snapshot extra");
    }

    private static void nonnegative(long value, String name) {
        if (value < 0) {
            throw new IllegalArgumentException(name + " must not be negative");
        }
    }

    private static void positive(long value, String name) {
        if (value <= 0) {
            throw new IllegalArgumentException(name + " must be positive");
        }
    }

    private static void positiveUint16(long value, String name) {
        if (value <= 0 || value > 0xffffL) {
            throw new IllegalArgumentException(
                name + " must be positive and fit uint16"
            );
        }
    }

    private static void positiveUint32(long value, String name) {
        if (value <= 0 || value > 0xffff_ffffL) {
            throw new IllegalArgumentException(
                name + " must be positive and fit uint32"
            );
        }
    }

    private static void oneOf(String value, String name, String... allowed) {
        Objects.requireNonNull(value, name);
        for (String candidate : allowed) {
            if (candidate.equals(value)) {
                return;
            }
        }
        throw new IllegalArgumentException(name + " has an unsupported value");
    }
}
