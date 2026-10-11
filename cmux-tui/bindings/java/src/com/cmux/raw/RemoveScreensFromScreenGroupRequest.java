// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable remove-screens-from-screen-group request. Protocol v12; authority: control. */
public final class RemoveScreensFromScreenGroupRequest implements WireValue {
    private final List<UInt64> screens;

    private RemoveScreensFromScreenGroupRequest(Builder builder) {
        if (!builder.screensSet) throw new IllegalArgumentException("screens is required");
        this.screens = List.copyOf(Wire.nonNull(builder.screens, "screens"));
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> screens() { return screens; }

    public static RemoveScreensFromScreenGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoveScreensFromScreenGroupRequest");
        Builder builder = builder();
        Object rawScreens = Wire.required(object, "screens");
        builder.screens(Wire.array(rawScreens, "RemoveScreensFromScreenGroupRequest.screens", item -> Wire.uint64(item, "RemoveScreensFromScreenGroupRequest.screens item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "screens", screens);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RemoveScreensFromScreenGroupRequest that)) return false;
        return Objects.equals(screens, that.screens);
    }

    @Override
    public int hashCode() { return Objects.hash(screens); }

    @Override
    public String toString() { return "RemoveScreensFromScreenGroupRequest" + toWire(); }

    public static final class Builder {
        private List<UInt64> screens;
        private boolean screensSet;

        public Builder screens(List<UInt64> value) {
            this.screens = value;
            this.screensSet = true;
            return this;
        }
        public RemoveScreensFromScreenGroupRequest build() { return new RemoveScreensFromScreenGroupRequest(this); }
    }
}
