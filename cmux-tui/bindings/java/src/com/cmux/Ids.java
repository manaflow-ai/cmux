package com.cmux;

import java.util.Objects;

/** Opaque, resource-specific protocol-v2 identifiers. */
public final class Ids {
    public sealed interface Id permits MachineId, SessionId, WorkspaceId, ScreenId,
            PaneId, TabId, TerminalId, BrowserId, ConnectedClientId, SplitId,
            NotificationId, AgentId, StreamId, ProjectionId, PairingRequestId,
            SidebarViewId {
        String value();
    }

    public record MachineId(String value) implements Id {
        public MachineId { value = validate(value, "machine"); }
    }
    public record SessionId(String value) implements Id {
        public SessionId { value = validate(value, "session"); }
    }
    public record WorkspaceId(String value) implements Id {
        public WorkspaceId { value = validate(value, "ws"); }
    }
    public record ScreenId(String value) implements Id {
        public ScreenId { value = validate(value, "screen"); }
    }
    public record PaneId(String value) implements Id {
        public PaneId { value = validate(value, "pane"); }
    }
    public record TabId(String value) implements Id {
        public TabId { value = validate(value, "tab"); }
    }
    public record TerminalId(String value) implements Id {
        public TerminalId { value = validate(value, "term"); }
    }
    public record BrowserId(String value) implements Id {
        public BrowserId { value = validate(value, "browser"); }
    }
    public record ConnectedClientId(String value) implements Id {
        public ConnectedClientId { value = validate(value, "client"); }
    }
    public record SplitId(String value) implements Id {
        public SplitId { value = validate(value, "split"); }
    }
    public record NotificationId(String value) implements Id {
        public NotificationId { value = validate(value, "notification"); }
    }
    public record AgentId(String value) implements Id {
        public AgentId { value = validate(value, "agent"); }
    }
    public record StreamId(String value) implements Id {
        public StreamId { value = validate(value, "stream"); }
    }
    public record ProjectionId(String value) implements Id {
        public ProjectionId { value = validate(value, "projection"); }
    }
    public record PairingRequestId(String value) implements Id {
        public PairingRequestId { value = validate(value, "pairing"); }
    }
    public record SidebarViewId(String value) implements Id {
        public SidebarViewId { value = validate(value, "sidebar_view"); }
    }
    private Ids() {}

    private static String validate(String value, String prefix) {
        Objects.requireNonNull(value, "value");
        String marker = prefix + "_";
        if (!value.startsWith(marker) || value.length() != marker.length() + 32) {
            throw new IllegalArgumentException(
                "expected " + marker + " followed by 32 lowercase hexadecimal characters"
            );
        }
        for (int index = marker.length(); index < value.length(); index++) {
            char character = value.charAt(index);
            if (!((character >= '0' && character <= '9') ||
                    (character >= 'a' && character <= 'f'))) {
                throw new IllegalArgumentException(
                    "expected " + marker + " followed by 32 lowercase hexadecimal characters"
                );
            }
        }
        return value;
    }
}
