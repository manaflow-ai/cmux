// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-local-read request. Protocol v12; authority: control. */
public final class FeedLocalReadRequest implements WireValue {
    private final List<String> items;

    private FeedLocalReadRequest(Builder builder) {
        if (!builder.itemsSet) throw new IllegalArgumentException("items is required");
        this.items = List.copyOf(Wire.nonNull(builder.items, "items"));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> items() { return items; }

    public static FeedLocalReadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedLocalReadRequest");
        Builder builder = builder();
        Object rawItems = Wire.required(object, "items");
        builder.items(Wire.array(rawItems, "FeedLocalReadRequest.items", item -> Wire.string(item, "FeedLocalReadRequest.items item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "items", items);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedLocalReadRequest that)) return false;
        return Objects.equals(items, that.items);
    }

    @Override
    public int hashCode() { return Objects.hash(items); }

    @Override
    public String toString() { return "FeedLocalReadRequest" + toWire(); }

    public static final class Builder {
        private List<String> items;
        private boolean itemsSet;

        public Builder items(List<String> value) {
            this.items = value;
            this.itemsSet = true;
            return this;
        }
        public FeedLocalReadRequest build() { return new FeedLocalReadRequest(this); }
    }
}
