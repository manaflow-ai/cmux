// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable render-delta event. Protocol v7; streams: attach-render. */
public final class RenderDeltaEvent implements WireValue, ProtocolEvent, RenderAttachEvent {
    private final RenderCursor cursor;
    private final Field<String> defaultBg;
    private final Field<String> defaultFg;
    private final boolean full;
    private final Field<RenderGraphicsDelta> graphics;
    private final Field<UInt64> historyEpoch;
    private final List<RenderRow> rows;
    private final Field<Long> scrollbackRows;
    private final Field<Size> size;
    private final UInt64 surface;

    private RenderDeltaEvent(Builder builder) {
        if (!builder.cursorSet) throw new IllegalArgumentException("cursor is required");
        this.cursor = Wire.nonNull(builder.cursor, "cursor");
        this.defaultBg = builder.defaultBg;
        this.defaultFg = builder.defaultFg;
        if (!builder.fullSet) throw new IllegalArgumentException("full is required");
        this.full = builder.full;
        this.graphics = builder.graphics;
        this.historyEpoch = builder.historyEpoch;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
        this.scrollbackRows = builder.scrollbackRows;
        this.size = builder.size;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public RenderCursor cursor() { return cursor; }
    public Field<String> defaultBg() { return defaultBg; }
    public Field<String> defaultFg() { return defaultFg; }
    public boolean full() { return full; }
    public Field<RenderGraphicsDelta> graphics() { return graphics; }
    public Field<UInt64> historyEpoch() { return historyEpoch; }
    public List<RenderRow> rows() { return rows; }
    public Field<Long> scrollbackRows() { return scrollbackRows; }
    public Field<Size> size() { return size; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "render-delta"; }

    public static RenderDeltaEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderDeltaEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "render-delta", "RenderDeltaEvent.event");
        Object rawCursor = Wire.required(object, "cursor");
        builder.cursor(RenderCursor.fromWire(rawCursor));
        Object rawDefaultBg = Wire.optional(object, "default_bg");
        if (!Wire.isMissing(rawDefaultBg)) {
            builder.defaultBg(Wire.string(rawDefaultBg, "RenderDeltaEvent.default_bg"));
        }
        Object rawDefaultFg = Wire.optional(object, "default_fg");
        if (!Wire.isMissing(rawDefaultFg)) {
            builder.defaultFg(Wire.string(rawDefaultFg, "RenderDeltaEvent.default_fg"));
        }
        Object rawFull = Wire.required(object, "full");
        builder.full(Wire.bool(rawFull, "RenderDeltaEvent.full"));
        Object rawGraphics = Wire.optional(object, "graphics");
        if (!Wire.isMissing(rawGraphics)) {
            builder.graphics(RenderGraphicsDelta.fromWire(rawGraphics));
        }
        Object rawHistoryEpoch = Wire.optional(object, "history_epoch");
        if (!Wire.isMissing(rawHistoryEpoch)) {
            builder.historyEpoch(Wire.uint64(rawHistoryEpoch, "RenderDeltaEvent.history_epoch"));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "RenderDeltaEvent.rows", item -> RenderRow.fromWire(item)));
        Object rawScrollbackRows = Wire.optional(object, "scrollback_rows");
        if (!Wire.isMissing(rawScrollbackRows)) {
            builder.scrollbackRows(Wire.uint32(rawScrollbackRows, "RenderDeltaEvent.scrollback_rows"));
        }
        Object rawSize = Wire.optional(object, "size");
        if (!Wire.isMissing(rawSize)) {
            builder.size(Size.fromWire(rawSize));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "RenderDeltaEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "render-delta");
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "default_bg", defaultBg);
        Wire.put(object, "default_fg", defaultFg);
        Wire.put(object, "full", full);
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
        if (!(other instanceof RenderDeltaEvent that)) return false;
        return Objects.equals(cursor, that.cursor) && Objects.equals(defaultBg, that.defaultBg) && Objects.equals(defaultFg, that.defaultFg) && Objects.equals(full, that.full) && Objects.equals(graphics, that.graphics) && Objects.equals(historyEpoch, that.historyEpoch) && Objects.equals(rows, that.rows) && Objects.equals(scrollbackRows, that.scrollbackRows) && Objects.equals(size, that.size) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cursor, defaultBg, defaultFg, full, graphics, historyEpoch, rows, scrollbackRows, size, surface); }

    @Override
    public String toString() { return "RenderDeltaEvent" + toWire(); }

    public static final class Builder {
        private RenderCursor cursor;
        private boolean cursorSet;
        private Field<String> defaultBg = Field.omitted();
        private Field<String> defaultFg = Field.omitted();
        private Boolean full;
        private boolean fullSet;
        private Field<RenderGraphicsDelta> graphics = Field.omitted();
        private Field<UInt64> historyEpoch = Field.omitted();
        private List<RenderRow> rows;
        private boolean rowsSet;
        private Field<Long> scrollbackRows = Field.omitted();
        private Field<Size> size = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cursor(RenderCursor value) {
            this.cursor = value;
            this.cursorSet = true;
            return this;
        }
        public Builder defaultBg(String value) {
            this.defaultBg = Field.of(value);
            return this;
        }
        public Builder defaultFg(String value) {
            this.defaultFg = Field.of(value);
            return this;
        }
        public Builder full(boolean value) {
            this.full = value;
            this.fullSet = true;
            return this;
        }
        public Builder graphics(RenderGraphicsDelta value) {
            this.graphics = Field.of(value);
            return this;
        }
        public Builder historyEpoch(UInt64 value) {
            this.historyEpoch = Field.of(value);
            return this;
        }
        public Builder rows(List<RenderRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder scrollbackRows(Long value) {
            this.scrollbackRows = Field.of(value);
            return this;
        }
        public Builder size(Size value) {
            this.size = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public RenderDeltaEvent build() { return new RenderDeltaEvent(this); }
    }
}
