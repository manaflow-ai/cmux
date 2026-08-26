// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-frame-presented request. Protocol v10; authority: frontend. */
public final class BrowserFramePresentedRequest implements WireValue {
    private final UInt64 frameSeq;
    private final UInt64 surface;

    private BrowserFramePresentedRequest(Builder builder) {
        if (!builder.frameSeqSet) throw new IllegalArgumentException("frame_seq is required");
        this.frameSeq = Wire.nonNull(builder.frameSeq, "frame_seq");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 frameSeq() { return frameSeq; }
    public UInt64 surface() { return surface; }

    public static BrowserFramePresentedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserFramePresentedRequest");
        Builder builder = builder();
        Object rawFrameSeq = Wire.required(object, "frame_seq");
        builder.frameSeq(Wire.uint64(rawFrameSeq, "BrowserFramePresentedRequest.frame_seq"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserFramePresentedRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "frame_seq", frameSeq);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserFramePresentedRequest that)) return false;
        return Objects.equals(frameSeq, that.frameSeq) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(frameSeq, surface); }

    @Override
    public String toString() { return "BrowserFramePresentedRequest" + toWire(); }

    public static final class Builder {
        private UInt64 frameSeq;
        private boolean frameSeqSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder frameSeq(UInt64 value) {
            this.frameSeq = value;
            this.frameSeqSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public BrowserFramePresentedRequest build() { return new BrowserFramePresentedRequest(this); }
    }
}
