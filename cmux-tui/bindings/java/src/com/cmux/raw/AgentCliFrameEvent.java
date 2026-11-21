// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-frame event. Protocol v12; streams: attach-byte. */
public final class AgentCliFrameEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final UInt64 base;
    private final int cols;
    private final boolean cursorVisible;
    private final int cursorX;
    private final int cursorY;
    private final Bytes data;
    private final UInt64 frame;
    private final int rows;
    private final String stream;
    private final UInt64 surface;

    private AgentCliFrameEvent(Builder builder) {
        if (!builder.baseSet) throw new IllegalArgumentException("base is required");
        this.base = builder.base;
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.cursorVisibleSet) throw new IllegalArgumentException("cursor_visible is required");
        this.cursorVisible = builder.cursorVisible;
        if (!builder.cursorXSet) throw new IllegalArgumentException("cursor_x is required");
        this.cursorX = builder.cursorX;
        if (!builder.cursorYSet) throw new IllegalArgumentException("cursor_y is required");
        this.cursorY = builder.cursorY;
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.frameSet) throw new IllegalArgumentException("frame is required");
        this.frame = Wire.nonNull(builder.frame, "frame");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 base() { return base; }
    public int cols() { return cols; }
    public boolean cursorVisible() { return cursorVisible; }
    public int cursorX() { return cursorX; }
    public int cursorY() { return cursorY; }
    public Bytes data() { return data; }
    public UInt64 frame() { return frame; }
    public int rows() { return rows; }
    public String stream() { return stream; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "agent-cli-frame"; }

    public static AgentCliFrameEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliFrameEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-cli-frame", "AgentCliFrameEvent.event");
        Object rawBase = Wire.required(object, "base");
        builder.base(rawBase == null ? null : Wire.uint64(rawBase, "AgentCliFrameEvent.base"));
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "AgentCliFrameEvent.cols"));
        Object rawCursorVisible = Wire.required(object, "cursor_visible");
        builder.cursorVisible(Wire.bool(rawCursorVisible, "AgentCliFrameEvent.cursor_visible"));
        Object rawCursorX = Wire.required(object, "cursor_x");
        builder.cursorX(Wire.uint16(rawCursorX, "AgentCliFrameEvent.cursor_x"));
        Object rawCursorY = Wire.required(object, "cursor_y");
        builder.cursorY(Wire.uint16(rawCursorY, "AgentCliFrameEvent.cursor_y"));
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "AgentCliFrameEvent.data"));
        Object rawFrame = Wire.required(object, "frame");
        builder.frame(Wire.uint64(rawFrame, "AgentCliFrameEvent.frame"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "AgentCliFrameEvent.rows"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.string(rawStream, "AgentCliFrameEvent.stream"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentCliFrameEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-cli-frame");
        Wire.put(object, "base", base);
        Wire.put(object, "cols", cols);
        Wire.put(object, "cursor_visible", cursorVisible);
        Wire.put(object, "cursor_x", cursorX);
        Wire.put(object, "cursor_y", cursorY);
        Wire.put(object, "data", data);
        Wire.put(object, "frame", frame);
        Wire.put(object, "rows", rows);
        Wire.put(object, "stream", stream);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliFrameEvent that)) return false;
        return Objects.equals(base, that.base) && Objects.equals(cols, that.cols) && Objects.equals(cursorVisible, that.cursorVisible) && Objects.equals(cursorX, that.cursorX) && Objects.equals(cursorY, that.cursorY) && Objects.equals(data, that.data) && Objects.equals(frame, that.frame) && Objects.equals(rows, that.rows) && Objects.equals(stream, that.stream) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(base, cols, cursorVisible, cursorX, cursorY, data, frame, rows, stream, surface); }

    @Override
    public String toString() { return "AgentCliFrameEvent" + toWire(); }

    public static final class Builder {
        private UInt64 base;
        private boolean baseSet;
        private Integer cols;
        private boolean colsSet;
        private Boolean cursorVisible;
        private boolean cursorVisibleSet;
        private Integer cursorX;
        private boolean cursorXSet;
        private Integer cursorY;
        private boolean cursorYSet;
        private Bytes data;
        private boolean dataSet;
        private UInt64 frame;
        private boolean frameSet;
        private Integer rows;
        private boolean rowsSet;
        private String stream;
        private boolean streamSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder base(UInt64 value) {
            this.base = value;
            this.baseSet = true;
            return this;
        }
        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder cursorVisible(boolean value) {
            this.cursorVisible = value;
            this.cursorVisibleSet = true;
            return this;
        }
        public Builder cursorX(int value) {
            this.cursorX = value;
            this.cursorXSet = true;
            return this;
        }
        public Builder cursorY(int value) {
            this.cursorY = value;
            this.cursorYSet = true;
            return this;
        }
        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder frame(UInt64 value) {
            this.frame = value;
            this.frameSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder stream(String value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentCliFrameEvent build() { return new AgentCliFrameEvent(this); }
    }
}
