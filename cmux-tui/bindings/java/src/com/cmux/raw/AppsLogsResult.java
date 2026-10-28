// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsLogsResult implements WireValue {
    private final List<AppLogLine> lines;

    private AppsLogsResult(Builder builder) {
        if (!builder.linesSet) throw new IllegalArgumentException("lines is required");
        this.lines = List.copyOf(Wire.nonNull(builder.lines, "lines"));
    }

    public static Builder builder() { return new Builder(); }

    public List<AppLogLine> lines() { return lines; }

    public static AppsLogsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsLogsResult");
        Builder builder = builder();
        Object rawLines = Wire.required(object, "lines");
        builder.lines(Wire.array(rawLines, "AppsLogsResult.lines", item -> AppLogLine.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "lines", lines);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsLogsResult that)) return false;
        return Objects.equals(lines, that.lines);
    }

    @Override
    public int hashCode() { return Objects.hash(lines); }

    @Override
    public String toString() { return "AppsLogsResult" + toWire(); }

    public static final class Builder {
        private List<AppLogLine> lines;
        private boolean linesSet;

        public Builder lines(List<AppLogLine> value) {
            this.lines = value;
            this.linesSet = true;
            return this;
        }
        public AppsLogsResult build() { return new AppsLogsResult(this); }
    }
}
