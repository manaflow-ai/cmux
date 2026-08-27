package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Open typed union for sidebar attachment items. */
public sealed interface SidebarViewItem permits
        SidebarViewItem.Snapshot,
        SidebarViewItem.Patch,
        SidebarViewItem.Scroll,
        SidebarViewItem.Unknown {
    String kind();

    record Snapshot(
        Snapshots.SidebarViewSnapshot sidebarView,
        Render.Snapshot render
    ) implements SidebarViewItem {
        public Snapshot {
            Objects.requireNonNull(sidebarView, "sidebarView");
            Objects.requireNonNull(render, "render");
        }

        @Override
        public String kind() {
            return "snapshot";
        }
    }

    record Patch(
        Ids.SidebarViewId sidebarViewId,
        Render.Patch render
    ) implements SidebarViewItem {
        public Patch {
            Objects.requireNonNull(sidebarViewId, "sidebarViewId");
            Objects.requireNonNull(render, "render");
        }

        @Override
        public String kind() {
            return "patch";
        }
    }

    record Scroll(
        Ids.SidebarViewId sidebarViewId,
        Render.Scroll scroll
    ) implements SidebarViewItem {
        public Scroll {
            Objects.requireNonNull(sidebarViewId, "sidebarViewId");
            Objects.requireNonNull(scroll, "scroll");
        }

        @Override
        public String kind() {
            return "scroll";
        }
    }

    record Unknown(String kind, Map<String, Object> raw)
            implements SidebarViewItem {
        public Unknown {
            Objects.requireNonNull(kind, "kind");
            if (kind.isEmpty() ||
                    List.of("snapshot", "patch", "scroll").contains(kind)) {
                throw new IllegalArgumentException(
                    "unknown item requires an unrecognized non-empty kind"
                );
            }
            raw = JsonValue.immutableObject(raw, "unknown sidebar attachment");
        }
    }
}
