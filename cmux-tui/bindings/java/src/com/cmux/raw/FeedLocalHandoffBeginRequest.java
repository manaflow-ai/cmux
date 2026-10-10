// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-local-handoff-begin request. Protocol v12; authority: local-admin. */
public final class FeedLocalHandoffBeginRequest implements WireValue {
    private final String item;

    private FeedLocalHandoffBeginRequest(Builder builder) {
        if (!builder.itemSet) throw new IllegalArgumentException("item is required");
        this.item = Wire.nonNull(builder.item, "item");
    }

    public static Builder builder() { return new Builder(); }

    public String item() { return item; }

    public static FeedLocalHandoffBeginRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedLocalHandoffBeginRequest");
        Builder builder = builder();
        Object rawItem = Wire.required(object, "item");
        builder.item(Wire.string(rawItem, "FeedLocalHandoffBeginRequest.item"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "item", item);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedLocalHandoffBeginRequest that)) return false;
        return Objects.equals(item, that.item);
    }

    @Override
    public int hashCode() { return Objects.hash(item); }

    @Override
    public String toString() { return "FeedLocalHandoffBeginRequest" + toWire(); }

    public static final class Builder {
        private String item;
        private boolean itemSet;

        public Builder item(String value) {
            this.item = value;
            this.itemSet = true;
            return this;
        }
        public FeedLocalHandoffBeginRequest build() { return new FeedLocalHandoffBeginRequest(this); }
    }
}
