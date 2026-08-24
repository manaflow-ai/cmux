// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ApplyLayoutResult implements WireValue {
    private final List<AppliedPane> panes;
    private final UInt64 screen;

    private ApplyLayoutResult(Builder builder) {
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public List<AppliedPane> panes() { return panes; }
    public UInt64 screen() { return screen; }

    public static ApplyLayoutResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ApplyLayoutResult");
        Builder builder = builder();
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "ApplyLayoutResult.panes", item -> AppliedPane.fromWire(item)));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "ApplyLayoutResult.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "panes", panes);
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ApplyLayoutResult that)) return false;
        return Objects.equals(panes, that.panes) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(panes, screen); }

    @Override
    public String toString() { return "ApplyLayoutResult" + toWire(); }

    public static final class Builder {
        private List<AppliedPane> panes;
        private boolean panesSet;
        private UInt64 screen;
        private boolean screenSet;

        public Builder panes(List<AppliedPane> value) {
            this.panes = value;
            this.panesSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public ApplyLayoutResult build() { return new ApplyLayoutResult(this); }
    }
}
