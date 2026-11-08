package com.cmux;

import java.util.Map;
import java.util.Objects;

/** Typed session-delta resource change. */
public sealed interface ResourceChange permits
        ResourceChange.Upsert, ResourceChange.Delete, ResourceChange.Unknown {
    String kind();

    record Upsert(
        long sequence,
        ResourceKind resource,
        Ids.Id id,
        ResourceEntitySnapshot value
    ) implements ResourceChange {
        public Upsert {
            uint32(sequence);
            Objects.requireNonNull(resource, "resource");
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(value, "value");
            resource.requireMatches(id, value);
        }

        @Override
        public String kind() {
            return "upsert";
        }
    }

    record Delete(
        long sequence,
        ResourceKind resource,
        Ids.Id id
    ) implements ResourceChange {
        public Delete {
            uint32(sequence);
            Objects.requireNonNull(resource, "resource");
            Objects.requireNonNull(id, "id");
            resource.requireMatchesId(id);
        }

        @Override
        public String kind() {
            return "delete";
        }
    }

    record Unknown(String kind, Map<String, Object> raw)
            implements ResourceChange {
        public Unknown {
            Objects.requireNonNull(kind, "kind");
            if (kind.isEmpty() || kind.equals("upsert") || kind.equals("delete")) {
                throw new IllegalArgumentException(
                    "unknown change requires an unrecognized non-empty kind"
                );
            }
            raw = JsonValue.immutableObject(raw, "unknown resource change");
        }
    }

    enum ResourceKind {
        MACHINE,
        SESSION,
        WORKSPACE,
        SCREEN,
        PANE,
        TAB,
        TERMINAL,
        BROWSER,
        CLIENT,
        NOTIFICATION,
        AGENT,
        PAIRING_REQUEST,
        FRONTEND_PROJECTION,
        SIDEBAR_VIEW;

        public String toWire() {
            return name().toLowerCase(java.util.Locale.ROOT);
        }

        void requireMatches(Ids.Id id, ResourceEntitySnapshot value) {
            requireMatchesId(id);
            Class<?> expected = switch (this) {
                case MACHINE -> Snapshots.MachineSnapshot.class;
                case SESSION -> Snapshots.SessionSnapshot.class;
                case WORKSPACE -> Snapshots.WorkspaceSnapshot.class;
                case SCREEN -> Snapshots.ScreenSnapshot.class;
                case PANE -> Snapshots.PaneSnapshot.class;
                case TAB -> Snapshots.TabSnapshot.class;
                case TERMINAL -> Snapshots.TerminalSnapshot.class;
                case BROWSER -> Snapshots.BrowserSnapshot.class;
                case CLIENT -> Snapshots.ClientSnapshot.class;
                case NOTIFICATION -> Snapshots.NotificationSnapshot.class;
                case AGENT -> Snapshots.AgentSnapshot.class;
                case PAIRING_REQUEST -> Snapshots.PairingRequestSnapshot.class;
                case FRONTEND_PROJECTION ->
                    Snapshots.FrontendProjectionSnapshot.class;
                case SIDEBAR_VIEW -> Snapshots.SidebarViewSnapshot.class;
            };
            if (!expected.isInstance(value)) {
                throw new IllegalArgumentException(
                    "resource and snapshot type do not match"
                );
            }
        }

        void requireMatchesId(Ids.Id id) {
            Class<?> expected = switch (this) {
                case MACHINE -> Ids.MachineId.class;
                case SESSION -> Ids.SessionId.class;
                case WORKSPACE -> Ids.WorkspaceId.class;
                case SCREEN -> Ids.ScreenId.class;
                case PANE -> Ids.PaneId.class;
                case TAB -> Ids.TabId.class;
                case TERMINAL -> Ids.TerminalId.class;
                case BROWSER -> Ids.BrowserId.class;
                case CLIENT -> Ids.ConnectedClientId.class;
                case NOTIFICATION -> Ids.NotificationId.class;
                case AGENT -> Ids.AgentId.class;
                case PAIRING_REQUEST -> Ids.PairingRequestId.class;
                case FRONTEND_PROJECTION -> Ids.ProjectionId.class;
                case SIDEBAR_VIEW -> Ids.SidebarViewId.class;
            };
            if (!expected.isInstance(id)) {
                throw new IllegalArgumentException(
                    "resource and ID type do not match"
                );
            }
        }
    }

    private static void uint32(long value) {
        if (value < 0 || value > 0xffff_ffffL) {
            throw new IllegalArgumentException("sequence must fit uint32");
        }
    }
}
