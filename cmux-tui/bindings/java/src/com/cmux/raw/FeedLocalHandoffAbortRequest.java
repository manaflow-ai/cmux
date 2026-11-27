// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-local-handoff-abort request. Protocol v12; authority: local-admin. */
public final class FeedLocalHandoffAbortRequest implements WireValue {
    private final String item;

    private FeedLocalHandoffAbortRequest(Builder builder) {
        if (!builder.itemSet) throw new IllegalArgumentException("item is required");
        this.item = Wire.nonNull(builder.item, "item");
    }

    public static Builder builder() { return new Builder(); }

    public String item() { return item; }

    public static FeedLocalHandoffAbortRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedLocalHandoffAbortRequest");
        Builder builder = builder();
        Object rawItem = Wire.required(object, "item");
        builder.item(Wire.string(rawItem, "FeedLocalHandoffAbortRequest.item"));
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
        if (!(other instanceof FeedLocalHandoffAbortRequest that)) return false;
        return Objects.equals(item, that.item);
    }

    @Override
    public int hashCode() { return Objects.hash(item); }

    @Override
    public String toString() { return "FeedLocalHandoffAbortRequest" + toWire(); }

    public static final class Builder {
        private String item;
        private boolean itemSet;

        public Builder item(String value) {
            this.item = value;
            this.itemSet = true;
            return this;
        }
        public FeedLocalHandoffAbortRequest build() { return new FeedLocalHandoffAbortRequest(this); }
    }
}
