// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable render-state event. Protocol v7; streams: attach-render. */
public final class RenderStateEvent implements WireValue, ProtocolEvent, RenderAttachEvent {
    private final RenderCursor cursor;
    private final String defaultBg;
    private final String defaultFg;
    private final Field<RenderGraphics> graphics;
    private final UInt64 historyEpoch;
    private final List<RenderRow> rows;
    private final long scrollbackRows;
    private final Size size;
    private final UInt64 surface;

    private RenderStateEvent(Builder builder) {
        if (!builder.cursorSet) throw new IllegalArgumentException("cursor is required");
        this.cursor = Wire.nonNull(builder.cursor, "cursor");
        if (!builder.defaultBgSet) throw new IllegalArgumentException("default_bg is required");
        this.defaultBg = Wire.nonNull(builder.defaultBg, "default_bg");
        if (!builder.defaultFgSet) throw new IllegalArgumentException("default_fg is required");
        this.defaultFg = Wire.nonNull(builder.defaultFg, "default_fg");
        this.graphics = builder.graphics;
        if (!builder.historyEpochSet) throw new IllegalArgumentException("history_epoch is required");
        this.historyEpoch = Wire.nonNull(builder.historyEpoch, "history_epoch");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
        if (!builder.scrollbackRowsSet) throw new IllegalArgumentException("scrollback_rows is required");
        this.scrollbackRows = builder.scrollbackRows;
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = Wire.nonNull(builder.size, "size");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public RenderCursor cursor() { return cursor; }
    public String defaultBg() { return defaultBg; }
    public String defaultFg() { return defaultFg; }
    public Field<RenderGraphics> graphics() { return graphics; }
    public UInt64 historyEpoch() { return historyEpoch; }
    public List<RenderRow> rows() { return rows; }
    public long scrollbackRows() { return scrollbackRows; }
    public Size size() { return size; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "render-state"; }

    public static RenderStateEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderStateEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "render-state", "RenderStateEvent.event");
        Object rawCursor = Wire.required(object, "cursor");
        builder.cursor(RenderCursor.fromWire(rawCursor));
        Object rawDefaultBg = Wire.required(object, "default_bg");
        builder.defaultBg(Wire.string(rawDefaultBg, "RenderStateEvent.default_bg"));
        Object rawDefaultFg = Wire.required(object, "default_fg");
        builder.defaultFg(Wire.string(rawDefaultFg, "RenderStateEvent.default_fg"));
        Object rawGraphics = Wire.optional(object, "graphics");
        if (!Wire.isMissing(rawGraphics)) {
            builder.graphics(RenderGraphics.fromWire(rawGraphics));
        }
        Object rawHistoryEpoch = Wire.required(object, "history_epoch");
        builder.historyEpoch(Wire.uint64(rawHistoryEpoch, "RenderStateEvent.history_epoch"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "RenderStateEvent.rows", item -> RenderRow.fromWire(item)));
        Object rawScrollbackRows = Wire.required(object, "scrollback_rows");
        builder.scrollbackRows(Wire.uint32(rawScrollbackRows, "RenderStateEvent.scrollback_rows"));
        Object rawSize = Wire.required(object, "size");
        builder.size(Size.fromWire(rawSize));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "RenderStateEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "render-state");
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "default_bg", defaultBg);
        Wire.put(object, "default_fg", defaultFg);
        Wire.put(object, "graphics", graphics);
        Wire.put(object, "history_epoch", historyEpoch);
        Wire.put(object, "rows", rows);
        Wire.put(object, "scrollback_rows", scrollbackRows);
        Wire.put(object, "size", size);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderStateEvent that)) return false;
        return Objects.equals(cursor, that.cursor) && Objects.equals(defaultBg, that.defaultBg) && Objects.equals(defaultFg, that.defaultFg) && Objects.equals(graphics, that.graphics) && Objects.equals(historyEpoch, that.historyEpoch) && Objects.equals(rows, that.rows) && Objects.equals(scrollbackRows, that.scrollbackRows) && Objects.equals(size, that.size) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cursor, defaultBg, defaultFg, graphics, historyEpoch, rows, scrollbackRows, size, surface); }

    @Override
    public String toString() { return "RenderStateEvent" + toWire(); }

    public static final class Builder {
        private RenderCursor cursor;
        private boolean cursorSet;
        private String defaultBg;
        private boolean defaultBgSet;
        private String defaultFg;
        private boolean defaultFgSet;
        private Field<RenderGraphics> graphics = Field.omitted();
        private UInt64 historyEpoch;
        private boolean historyEpochSet;
        private List<RenderRow> rows;
        private boolean rowsSet;
        private Long scrollbackRows;
        private boolean scrollbackRowsSet;
        private Size size;
        private boolean sizeSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cursor(RenderCursor value) {
            this.cursor = value;
            this.cursorSet = true;
            return this;
        }
        public Builder defaultBg(String value) {
            this.defaultBg = value;
            this.defaultBgSet = true;
            return this;
        }
        public Builder defaultFg(String value) {
            this.defaultFg = value;
            this.defaultFgSet = true;
            return this;
        }
        public Builder graphics(RenderGraphics value) {
            this.graphics = Field.of(value);
            return this;
        }
        public Builder historyEpoch(UInt64 value) {
            this.historyEpoch = value;
            this.historyEpochSet = true;
            return this;
        }
        public Builder rows(List<RenderRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder scrollbackRows(long value) {
            this.scrollbackRows = value;
            this.scrollbackRowsSet = true;
            return this;
        }
        public Builder size(Size value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public RenderStateEvent build() { return new RenderStateEvent(this); }
    }
}
