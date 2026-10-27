// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcParses implements WireValue {
    private final ServerStatsIpcParse frames;
    private final ServerStatsIpcParse lines;

    private ServerStatsIpcParses(Builder builder) {
        if (!builder.framesSet) throw new IllegalArgumentException("frames is required");
        this.frames = Wire.nonNull(builder.frames, "frames");
        if (!builder.linesSet) throw new IllegalArgumentException("lines is required");
        this.lines = Wire.nonNull(builder.lines, "lines");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsIpcParse frames() { return frames; }
    public ServerStatsIpcParse lines() { return lines; }

    public static ServerStatsIpcParses fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcParses");
        Builder builder = builder();
        Object rawFrames = Wire.required(object, "frames");
        builder.frames(ServerStatsIpcParse.fromWire(rawFrames));
        Object rawLines = Wire.required(object, "lines");
        builder.lines(ServerStatsIpcParse.fromWire(rawLines));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "frames", frames);
        Wire.put(object, "lines", lines);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcParses that)) return false;
        return Objects.equals(frames, that.frames) && Objects.equals(lines, that.lines);
    }

    @Override
    public int hashCode() { return Objects.hash(frames, lines); }

    @Override
    public String toString() { return "ServerStatsIpcParses" + toWire(); }

    public static final class Builder {
        private ServerStatsIpcParse frames;
        private boolean framesSet;
        private ServerStatsIpcParse lines;
        private boolean linesSet;

        public Builder frames(ServerStatsIpcParse value) {
            this.frames = value;
            this.framesSet = true;
            return this;
        }
        public Builder lines(ServerStatsIpcParse value) {
            this.lines = value;
            this.linesSet = true;
            return this;
        }
        public ServerStatsIpcParses build() { return new ServerStatsIpcParses(this); }
    }
}
