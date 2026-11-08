package com.cmux;

import java.util.List;
import java.util.Objects;
import java.util.Optional;

/** Styled terminal/sidebar render values shared by snapshots, patches, and history. */
public final class Render {
    public record Cursor(
        int x,
        int y,
        String style,
        boolean blink,
        boolean visible,
        Optional<String> color
    ) {
        public Cursor {
            uint16(x, "x");
            uint16(y, "y");
            oneOf(style, "style", "block", "underline", "bar");
            color = optional(color);
            color.ifPresent(value -> Render.color(value, "color"));
        }
    }

    public record Run(
        String text,
        Optional<String> foreground,
        Optional<String> background,
        long attributes,
        Optional<String> underline,
        Optional<Integer> widthHint
    ) {
        public Run {
            Objects.requireNonNull(text, "text");
            foreground = optional(foreground);
            background = optional(background);
            foreground.ifPresent(value -> color(value, "foreground"));
            background.ifPresent(value -> color(value, "background"));
            if (attributes < 0 || attributes > 0xffff_ffffL) {
                throw new IllegalArgumentException("attributes must fit uint32");
            }
            underline = optional(underline);
            underline.ifPresent(value -> oneOf(
                value,
                "underline",
                "single",
                "double",
                "curly",
                "dotted",
                "dashed"
            ));
            widthHint = optional(widthHint);
            widthHint.ifPresent(value -> uint16(value, "widthHint"));
        }
    }

    public record Row(int row, List<Run> runs) {
        public Row {
            uint16(row, "row");
            runs = List.copyOf(runs);
        }
    }

    public record Snapshot(
        Snapshots.Size size,
        Cursor cursor,
        String defaultForeground,
        String defaultBackground,
        long scrollbackRows,
        List<Row> rows
    ) {
        public Snapshot {
            Objects.requireNonNull(size, "size");
            Objects.requireNonNull(cursor, "cursor");
            color(defaultForeground, "defaultForeground");
            color(defaultBackground, "defaultBackground");
            uint32(scrollbackRows, "scrollbackRows");
            rows = List.copyOf(rows);
            if (rows.size() != size.rows()) {
                throw new IllegalArgumentException(
                    "render snapshot rows must match size.rows"
                );
            }
        }
    }

    public record Patch(
        Cursor cursor,
        boolean fullReset,
        Optional<Snapshots.Size> size,
        Optional<String> defaultForeground,
        Optional<String> defaultBackground,
        Optional<Long> scrollbackRows,
        List<Row> rows
    ) {
        public Patch {
            Objects.requireNonNull(cursor, "cursor");
            size = optional(size);
            defaultForeground = optional(defaultForeground);
            defaultBackground = optional(defaultBackground);
            scrollbackRows = optional(scrollbackRows);
            defaultForeground.ifPresent(
                value -> color(value, "defaultForeground")
            );
            defaultBackground.ifPresent(
                value -> color(value, "defaultBackground")
            );
            scrollbackRows.ifPresent(value -> uint32(value, "scrollbackRows"));
            rows = List.copyOf(rows);
            if (size.isPresent() && !fullReset) {
                throw new IllegalArgumentException(
                    "a render resize requires fullReset"
                );
            }
            if (size.isPresent() && rows.size() != size.get().rows()) {
                throw new IllegalArgumentException(
                    "a resized render patch must contain the full viewport"
                );
            }
        }
    }

    public record Scroll(Decimal offset, boolean atBottom) {
        public Scroll {
            Objects.requireNonNull(offset, "offset");
        }
    }

    private Render() {}

    private static <T> Optional<T> optional(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }

    private static void uint16(long value, String name) {
        if (value < 0 || value > 0xffffL) {
            throw new IllegalArgumentException(name + " must fit uint16");
        }
    }

    private static void uint32(long value, String name) {
        if (value < 0 || value > 0xffff_ffffL) {
            throw new IllegalArgumentException(name + " must fit uint32");
        }
    }

    private static void color(String value, String name) {
        Objects.requireNonNull(value, name);
        if (!value.matches("#[0-9a-fA-F]{6}")) {
            throw new IllegalArgumentException(name + " must be #RRGGBB");
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
