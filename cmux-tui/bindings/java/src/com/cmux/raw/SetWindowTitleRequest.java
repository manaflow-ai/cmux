// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-window-title request. Protocol v6; authority: control. */
public final class SetWindowTitleRequest implements WireValue {
    private final String title;

    private SetWindowTitleRequest(Builder builder) {
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String title() { return title; }

    public static SetWindowTitleRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetWindowTitleRequest");
        Builder builder = builder();
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "SetWindowTitleRequest.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetWindowTitleRequest that)) return false;
        return Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(title); }

    @Override
    public String toString() { return "SetWindowTitleRequest" + toWire(); }

    public static final class Builder {
        private String title;
        private boolean titleSet;

        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public SetWindowTitleRequest build() { return new SetWindowTitleRequest(this); }
    }
}
