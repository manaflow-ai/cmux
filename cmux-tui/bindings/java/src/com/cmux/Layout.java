package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Lossless protocol-v2 screen layout values. */
public final class Layout {
    public sealed interface Node permits Leaf, Split, Stack, Viewport {
        String kind();
    }

    public record Leaf(
        Ids.PaneId paneId,
        List<Ids.TabId> tabIds,
        Optional<Ids.TabId> activeTabId
    ) implements Node {
        public Leaf {
            Objects.requireNonNull(paneId, "paneId");
            tabIds = List.copyOf(tabIds);
            activeTabId = optional(activeTabId);
        }

        @Override
        public String kind() {
            return "leaf";
        }
    }

    public record Split(
        Ids.SplitId splitId,
        String direction,
        double ratio,
        Node first,
        Node second
    ) implements Node {
        public Split {
            Objects.requireNonNull(splitId, "splitId");
            if (!direction.equals("horizontal") && !direction.equals("vertical")) {
                throw new IllegalArgumentException(
                    "direction must be horizontal or vertical"
                );
            }
            if (!Double.isFinite(ratio) || ratio <= 0.0 || ratio >= 1.0) {
                throw new IllegalArgumentException(
                    "ratio must be finite and between zero and one"
                );
            }
            Objects.requireNonNull(first, "first");
            Objects.requireNonNull(second, "second");
        }

        @Override
        public String kind() {
            return "split";
        }
    }

    public record Stack(
        List<Ids.PaneId> paneIds,
        Ids.PaneId expandedPaneId
    ) implements Node {
        public Stack {
            paneIds = List.copyOf(paneIds);
            if (paneIds.isEmpty()) {
                throw new IllegalArgumentException("paneIds must not be empty");
            }
            Objects.requireNonNull(expandedPaneId, "expandedPaneId");
            if (!paneIds.contains(expandedPaneId)) {
                throw new IllegalArgumentException(
                    "expandedPaneId must be present in paneIds"
                );
            }
        }

        @Override
        public String kind() {
            return "stack";
        }
    }

    public record Column(Ids.SplitId columnId, double width, Node root) {
        public Column {
            Objects.requireNonNull(columnId, "columnId");
            boundedWidth(width, "width");
            Objects.requireNonNull(root, "root");
        }
    }

    public record Viewport(double baseWidth, List<Column> columns)
            implements Node {
        public Viewport {
            boundedWidth(baseWidth, "baseWidth");
            columns = List.copyOf(columns);
            if (columns.isEmpty()) {
                throw new IllegalArgumentException("columns must not be empty");
            }
        }

        @Override
        public String kind() {
            return "viewport";
        }
    }

    public record Document(
        long version,
        Ids.ScreenId screenId,
        Ids.PaneId activePaneId,
        Optional<Ids.PaneId> zoomedPaneId,
        Node root,
        Map<String, Object> extra
    ) {
        public Document {
            if (version < 0 || version > 0xffff_ffffL) {
                throw new IllegalArgumentException("version must fit uint32");
            }
            Objects.requireNonNull(screenId, "screenId");
            Objects.requireNonNull(activePaneId, "activePaneId");
            zoomedPaneId = optional(zoomedPaneId);
            Objects.requireNonNull(root, "root");
            extra = extra == null
                ? Map.of()
                : JsonValue.immutableObject(extra, "layout extra");
        }
    }

    private Layout() {}

    private static <T> Optional<T> optional(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }

    private static void boundedWidth(double value, String name) {
        if (!Double.isFinite(value) || value < 0.1 || value > 1.0) {
            throw new IllegalArgumentException(
                name + " must be finite and between 0.1 and 1"
            );
        }
    }
}
