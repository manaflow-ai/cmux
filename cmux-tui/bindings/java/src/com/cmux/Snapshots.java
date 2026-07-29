package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Immutable protocol-v1 resource snapshots. */
public final class Snapshots {
    public record MachineSnapshot(
        Ids.MachineId id,
        String name,
        String origin,
        String status,
        boolean connectable,
        Optional<Ids.ProviderScopeId> providerScopeId,
        boolean deleted,
        boolean recoverable,
        Map<String, Object> extra
    ) {
        public MachineSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(name, "name");
            oneOf(origin, "origin", "local", "external");
            oneOf(
                status,
                "status",
                "running",
                "connecting",
                "sleeping",
                "stopped",
                "unavailable"
            );
            providerScopeId = opt(providerScopeId);
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
    ) {
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
        int index,
        boolean focused,
        Map<String, Object> extra
    ) {
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
        int index,
        boolean focused,
        Map<String, Object> layout,
        Map<String, Object> extra
    ) {
        public ScreenSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(workspaceId, "workspaceId");
            name = opt(name);
            nonnegative(index, "index");
            layout = copy(layout);
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
    ) {
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
        int index,
        boolean focused,
        String contentKind,
        Ids.Id contentId,
        Map<String, Object> extra
    ) {
        public TabSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(paneId, "paneId");
            name = opt(name);
            nonnegative(index, "index");
            Objects.requireNonNull(contentKind, "contentKind");
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

    public record TerminalSnapshot(
        Ids.TerminalId id,
        Ids.TabId tabId,
        String title,
        Optional<String> cwd,
        int columns,
        int rows,
        boolean running,
        Map<String, Object> extra
    ) {
        public TerminalSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(tabId, "tabId");
            Objects.requireNonNull(title, "title");
            cwd = opt(cwd);
            positive(columns, "columns");
            positive(rows, "rows");
            extra = copy(extra);
        }
    }

    public record Size(int columns, int rows) {
        public Size {
            positive(columns, "columns");
            positive(rows, "rows");
        }
    }

    public record PixelSize(long width, long height) {
        public PixelSize {
            positive(width, "width");
            positive(height, "height");
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
    ) {
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

    public record ConnectedClientSnapshot(
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
    ) {
        public ConnectedClientSnapshot {
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
            columns.ifPresent(value -> positive(value, "columns"));
            rows.ifPresent(value -> positive(value, "rows"));
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
    ) {
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
    ) {
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
    ) {
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
        Object projection,
        Map<String, Object> extra
    ) {
        public FrontendProjectionSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            projection = immutableJson(projection);
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
    ) {
        public SidebarViewSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(sessionId, "sessionId");
            positive(columns, "columns");
            positive(rows, "rows");
            extra = copy(extra);
        }
    }

    public record ProviderScopeSnapshot(
        Ids.ProviderScopeId id,
        String name,
        String kind,
        boolean canAdmin,
        boolean selected,
        Map<String, Object> extra
    ) {
        public ProviderScopeSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(name, "name");
            oneOf(kind, "kind", "personal", "team");
            extra = copy(extra);
        }
    }

    public record ProviderActionSnapshot(
        Ids.ProviderActionId id,
        Ids.ProviderScopeId providerScopeId,
        String name,
        String title,
        boolean enabled,
        String target,
        boolean destructive,
        List<ProviderActionField> fields,
        Map<String, Object> extra
    ) {
        public ProviderActionSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(providerScopeId, "providerScopeId");
            Objects.requireNonNull(name, "name");
            Objects.requireNonNull(title, "title");
            oneOf(
                target,
                "target",
                "scope",
                "selected_machine",
                "selected_workspace"
            );
            fields = List.copyOf(fields);
            extra = copy(extra);
        }
    }

    public record ProviderActionField(
        String id,
        String label,
        String kind,
        boolean required,
        Optional<Integer> maxLength,
        Optional<Integer> minimum,
        Optional<Integer> maximum,
        Optional<String> placeholder
    ) {
        public ProviderActionField {
            Objects.requireNonNull(id, "id");
            if (id.isEmpty()) {
                throw new IllegalArgumentException("provider action field id must not be empty");
            }
            Objects.requireNonNull(label, "label");
            oneOf(kind, "kind", "text", "email", "integer");
            maxLength = opt(maxLength);
            minimum = opt(minimum);
            maximum = opt(maximum);
            placeholder = opt(placeholder);
            maxLength.ifPresent(value -> positive(value, "maxLength"));
            if (minimum.isPresent() && maximum.isPresent() &&
                    minimum.get() > maximum.get()) {
                throw new IllegalArgumentException(
                    "provider action field minimum must not exceed maximum"
                );
            }
        }
    }

    public record ProviderNoticeSnapshot(
        Ids.ProviderNoticeId id,
        Ids.ProviderScopeId providerScopeId,
        String level,
        String message,
        Map<String, Object> extra
    ) {
        public ProviderNoticeSnapshot {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(providerScopeId, "providerScopeId");
            oneOf(level, "level", "info", "warning", "error");
            Objects.requireNonNull(message, "message");
            extra = copy(extra);
        }
    }

    private Snapshots() {}

    private static <T> Optional<T> opt(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }

    private static Map<String, Object> copy(Map<String, Object> value) {
        return value == null ? Map.of() : Map.copyOf(value);
    }

    private static Object immutableJson(Object value) {
        if (value instanceof Map<?, ?> map) {
            return Map.copyOf(map);
        }
        if (value instanceof List<?> list) {
            return List.copyOf(list);
        }
        return value;
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
