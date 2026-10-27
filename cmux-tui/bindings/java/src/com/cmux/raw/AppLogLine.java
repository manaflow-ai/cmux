// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppLogLine implements WireValue {
    private final String level;
    private final String message;
    private final UInt64 tsMs;

    private AppLogLine(Builder builder) {
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
        if (!builder.messageSet) throw new IllegalArgumentException("message is required");
        this.message = Wire.nonNull(builder.message, "message");
        if (!builder.tsMsSet) throw new IllegalArgumentException("ts_ms is required");
        this.tsMs = Wire.nonNull(builder.tsMs, "ts_ms");
    }

    public static Builder builder() { return new Builder(); }

    public String level() { return level; }
    public String message() { return message; }
    public UInt64 tsMs() { return tsMs; }

    public static AppLogLine fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppLogLine");
        Builder builder = builder();
        Object rawLevel = Wire.required(object, "level");
        builder.level(Wire.string(rawLevel, "AppLogLine.level"));
        Object rawMessage = Wire.required(object, "message");
        builder.message(Wire.string(rawMessage, "AppLogLine.message"));
        Object rawTsMs = Wire.required(object, "ts_ms");
        builder.tsMs(Wire.uint64(rawTsMs, "AppLogLine.ts_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "level", level);
        Wire.put(object, "message", message);
        Wire.put(object, "ts_ms", tsMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppLogLine that)) return false;
        return Objects.equals(level, that.level) && Objects.equals(message, that.message) && Objects.equals(tsMs, that.tsMs);
    }

    @Override
    public int hashCode() { return Objects.hash(level, message, tsMs); }

    @Override
    public String toString() { return "AppLogLine" + toWire(); }

    public static final class Builder {
        private String level;
        private boolean levelSet;
        private String message;
        private boolean messageSet;
        private UInt64 tsMs;
        private boolean tsMsSet;

        public Builder level(String value) {
            this.level = value;
            this.levelSet = true;
            return this;
        }
        public Builder message(String value) {
            this.message = value;
            this.messageSet = true;
            return this;
        }
        public Builder tsMs(UInt64 value) {
            this.tsMs = value;
            this.tsMsSet = true;
            return this;
        }
        public AppLogLine build() { return new AppLogLine(this); }
    }
}
