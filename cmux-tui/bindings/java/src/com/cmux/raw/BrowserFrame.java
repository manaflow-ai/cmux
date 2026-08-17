// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserFrame implements WireValue {
    private final Bytes data;
    private final long height;
    private final UInt64 seq;
    private final long width;

    private BrowserFrame(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = builder.height;
        if (!builder.seqSet) throw new IllegalArgumentException("seq is required");
        this.seq = Wire.nonNull(builder.seq, "seq");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Bytes data() { return data; }
    public long height() { return height; }
    public UInt64 seq() { return seq; }
    public long width() { return width; }

    public static BrowserFrame fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserFrame");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "BrowserFrame.data"));
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint32(rawHeight, "BrowserFrame.height"));
        Object rawSeq = Wire.required(object, "seq");
        builder.seq(Wire.uint64(rawSeq, "BrowserFrame.seq"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.uint32(rawWidth, "BrowserFrame.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "height", height);
        Wire.put(object, "seq", seq);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserFrame that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(height, that.height) && Objects.equals(seq, that.seq) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(data, height, seq, width); }

    @Override
    public String toString() { return "BrowserFrame" + toWire(); }

    public static final class Builder {
        private Bytes data;
        private boolean dataSet;
        private Long height;
        private boolean heightSet;
        private UInt64 seq;
        private boolean seqSet;
        private Long width;
        private boolean widthSet;

        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder height(long value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
        public Builder seq(UInt64 value) {
            this.seq = value;
            this.seqSet = true;
            return this;
        }
        public Builder width(long value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public BrowserFrame build() { return new BrowserFrame(this); }
    }
}
