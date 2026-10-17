// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HomeAgentsPaused implements WireValue {
    private final boolean main;
    private final List<String> threads;

    private HomeAgentsPaused(Builder builder) {
        if (!builder.mainSet) throw new IllegalArgumentException("main is required");
        this.main = builder.main;
        if (!builder.threadsSet) throw new IllegalArgumentException("threads is required");
        this.threads = List.copyOf(Wire.nonNull(builder.threads, "threads"));
    }

    public static Builder builder() { return new Builder(); }

    public boolean main() { return main; }
    public List<String> threads() { return threads; }

    public static HomeAgentsPaused fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeAgentsPaused");
        Builder builder = builder();
        Object rawMain = Wire.required(object, "main");
        builder.main(Wire.bool(rawMain, "HomeAgentsPaused.main"));
        Object rawThreads = Wire.required(object, "threads");
        builder.threads(Wire.array(rawThreads, "HomeAgentsPaused.threads", item -> Wire.string(item, "HomeAgentsPaused.threads item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "main", main);
        Wire.put(object, "threads", threads);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeAgentsPaused that)) return false;
        return Objects.equals(main, that.main) && Objects.equals(threads, that.threads);
    }

    @Override
    public int hashCode() { return Objects.hash(main, threads); }

    @Override
    public String toString() { return "HomeAgentsPaused" + toWire(); }

    public static final class Builder {
        private Boolean main;
        private boolean mainSet;
        private List<String> threads;
        private boolean threadsSet;

        public Builder main(boolean value) {
            this.main = value;
            this.mainSet = true;
            return this;
        }
        public Builder threads(List<String> value) {
            this.threads = value;
            this.threadsSet = true;
            return this;
        }
        public HomeAgentsPaused build() { return new HomeAgentsPaused(this); }
    }
}
