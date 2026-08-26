// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-state event. Protocol v6; streams: attach-browser. */
public final class BrowserStateEvent implements WireValue, BrowserAttachEvent, ProtocolEvent {
    private final int cols;
    private final String error;
    /** The initial browser-state includes the latest frame when one exists; later state updates omit it. */
    private final Field<BrowserFrame> frame;
    private final boolean framesStalled;
    private final int rows;
    private final BrowserStateEventStatus status;
    private final UInt64 surface;
    private final String title;
    private final String url;

    private BrowserStateEvent(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = builder.error;
        this.frame = builder.frame;
        if (!builder.framesStalledSet) throw new IllegalArgumentException("frames_stalled is required");
        this.framesStalled = builder.framesStalled;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public String error() { return error; }
    public Field<BrowserFrame> frame() { return frame; }
    public boolean framesStalled() { return framesStalled; }
    public int rows() { return rows; }
    public BrowserStateEventStatus status() { return status; }
    public UInt64 surface() { return surface; }
    public String title() { return title; }
    public String url() { return url; }
    @Override public String event() { return "browser-state"; }

    public static BrowserStateEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserStateEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "browser-state", "BrowserStateEvent.event");
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "BrowserStateEvent.cols"));
        Object rawError = Wire.required(object, "error");
        builder.error(rawError == null ? null : Wire.string(rawError, "BrowserStateEvent.error"));
        Object rawFrame = Wire.optional(object, "frame");
        if (!Wire.isMissing(rawFrame)) {
            builder.frame(rawFrame == null ? null : BrowserFrame.fromWire(rawFrame));
        }
        Object rawFramesStalled = Wire.required(object, "frames_stalled");
        builder.framesStalled(Wire.bool(rawFramesStalled, "BrowserStateEvent.frames_stalled"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "BrowserStateEvent.rows"));
        Object rawStatus = Wire.required(object, "status");
        builder.status(BrowserStateEventStatus.fromWire(rawStatus));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserStateEvent.surface"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "BrowserStateEvent.title"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "BrowserStateEvent.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "browser-state");
        Wire.put(object, "cols", cols);
        Wire.put(object, "error", error);
        Wire.put(object, "frame", frame);
        Wire.put(object, "frames_stalled", framesStalled);
        Wire.put(object, "rows", rows);
        Wire.put(object, "status", status);
        Wire.put(object, "surface", surface);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserStateEvent that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(error, that.error) && Objects.equals(frame, that.frame) && Objects.equals(framesStalled, that.framesStalled) && Objects.equals(rows, that.rows) && Objects.equals(status, that.status) && Objects.equals(surface, that.surface) && Objects.equals(title, that.title) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, error, frame, framesStalled, rows, status, surface, title, url); }

    @Override
    public String toString() { return "BrowserStateEvent" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private String error;
        private boolean errorSet;
        private Field<BrowserFrame> frame = Field.omitted();
        private Boolean framesStalled;
        private boolean framesStalledSet;
        private Integer rows;
        private boolean rowsSet;
        private BrowserStateEventStatus status;
        private boolean statusSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String title;
        private boolean titleSet;
        private String url;
        private boolean urlSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder frame(BrowserFrame value) {
            this.frame = Field.ofNullable(value);
            return this;
        }
        public Builder framesStalled(boolean value) {
            this.framesStalled = value;
            this.framesStalledSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder status(BrowserStateEventStatus value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public BrowserStateEvent build() { return new BrowserStateEvent(this); }
    }
}
