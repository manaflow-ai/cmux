// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable resized event. Protocol v6; streams: attach-byte. */
public final class ResizedEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final Field<TerminalColors> colors;
    private final int cols;
    /** Protocol 6 compatibility field. */
    private final Field<Bytes> data;
    private final Field<KittyGraphicsState> kittyGraphicsState;
    private final Field<List<KittyImageAlias>> kittyImageAliases;
    private final Field<Bytes> replay;
    private final int rows;
    private final UInt64 surface;

    private ResizedEvent(Builder builder) {
        this.colors = builder.colors;
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        this.data = builder.data;
        this.kittyGraphicsState = builder.kittyGraphicsState;
        this.kittyImageAliases = builder.kittyImageAliases.map(value -> List.copyOf(value));
        this.replay = builder.replay;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalColors> colors() { return colors; }
    public int cols() { return cols; }
    public Field<Bytes> data() { return data; }
    public Field<KittyGraphicsState> kittyGraphicsState() { return kittyGraphicsState; }
    public Field<List<KittyImageAlias>> kittyImageAliases() { return kittyImageAliases; }
    public Field<Bytes> replay() { return replay; }
    public int rows() { return rows; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "resized"; }

    public static ResizedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ResizedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "resized", "ResizedEvent.event");
        Object rawColors = Wire.optional(object, "colors");
        if (!Wire.isMissing(rawColors)) {
            builder.colors(TerminalColors.fromWire(rawColors));
        }
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "ResizedEvent.cols"));
        Object rawData = Wire.optional(object, "data");
        if (!Wire.isMissing(rawData)) {
            builder.data(Wire.bytes(rawData, "ResizedEvent.data"));
        }
        Object rawKittyGraphicsState = Wire.optional(object, "kitty_graphics_state");
        if (!Wire.isMissing(rawKittyGraphicsState)) {
            builder.kittyGraphicsState(KittyGraphicsState.fromWire(rawKittyGraphicsState));
        }
        Object rawKittyImageAliases = Wire.optional(object, "kitty_image_aliases");
        if (!Wire.isMissing(rawKittyImageAliases)) {
            builder.kittyImageAliases(Wire.array(rawKittyImageAliases, "ResizedEvent.kitty_image_aliases", item -> KittyImageAlias.fromWire(item)));
        }
        Object rawReplay = Wire.optional(object, "replay");
        if (!Wire.isMissing(rawReplay)) {
            builder.replay(Wire.bytes(rawReplay, "ResizedEvent.replay"));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "ResizedEvent.rows"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ResizedEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "resized");
        Wire.put(object, "colors", colors);
        Wire.put(object, "cols", cols);
        Wire.put(object, "data", data);
        Wire.put(object, "kitty_graphics_state", kittyGraphicsState);
        Wire.put(object, "kitty_image_aliases", kittyImageAliases);
        Wire.put(object, "replay", replay);
        Wire.put(object, "rows", rows);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ResizedEvent that)) return false;
        return Objects.equals(colors, that.colors) && Objects.equals(cols, that.cols) && Objects.equals(data, that.data) && Objects.equals(kittyGraphicsState, that.kittyGraphicsState) && Objects.equals(kittyImageAliases, that.kittyImageAliases) && Objects.equals(replay, that.replay) && Objects.equals(rows, that.rows) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(colors, cols, data, kittyGraphicsState, kittyImageAliases, replay, rows, surface); }

    @Override
    public String toString() { return "ResizedEvent" + toWire(); }

    public static final class Builder {
        private Field<TerminalColors> colors = Field.omitted();
        private Integer cols;
        private boolean colsSet;
        private Field<Bytes> data = Field.omitted();
        private Field<KittyGraphicsState> kittyGraphicsState = Field.omitted();
        private Field<List<KittyImageAlias>> kittyImageAliases = Field.omitted();
        private Field<Bytes> replay = Field.omitted();
        private Integer rows;
        private boolean rowsSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder colors(TerminalColors value) {
            this.colors = Field.of(value);
            return this;
        }
        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder data(Bytes value) {
            this.data = Field.of(value);
            return this;
        }
        public Builder kittyGraphicsState(KittyGraphicsState value) {
            this.kittyGraphicsState = Field.of(value);
            return this;
        }
        public Builder kittyImageAliases(List<KittyImageAlias> value) {
            this.kittyImageAliases = Field.of(value);
            return this;
        }
        public Builder replay(Bytes value) {
            this.replay = Field.of(value);
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ResizedEvent build() { return new ResizedEvent(this); }
    }
}
