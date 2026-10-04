// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-local-handoff-done request. Protocol v12; authority: local-admin. */
public final class FeedLocalHandoffDoneRequest implements WireValue {
    private final String home;
    private final String item;

    private FeedLocalHandoffDoneRequest(Builder builder) {
        if (!builder.homeSet) throw new IllegalArgumentException("home is required");
        this.home = Wire.nonNull(builder.home, "home");
        if (!builder.itemSet) throw new IllegalArgumentException("item is required");
        this.item = Wire.nonNull(builder.item, "item");
    }

    public static Builder builder() { return new Builder(); }

    public String home() { return home; }
    public String item() { return item; }

    public static FeedLocalHandoffDoneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedLocalHandoffDoneRequest");
        Builder builder = builder();
        Object rawHome = Wire.required(object, "home");
        builder.home(Wire.string(rawHome, "FeedLocalHandoffDoneRequest.home"));
        Object rawItem = Wire.required(object, "item");
        builder.item(Wire.string(rawItem, "FeedLocalHandoffDoneRequest.item"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "home", home);
        Wire.put(object, "item", item);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedLocalHandoffDoneRequest that)) return false;
        return Objects.equals(home, that.home) && Objects.equals(item, that.item);
    }

    @Override
    public int hashCode() { return Objects.hash(home, item); }

    @Override
    public String toString() { return "FeedLocalHandoffDoneRequest" + toWire(); }

    public static final class Builder {
        private String home;
        private boolean homeSet;
        private String item;
        private boolean itemSet;

        public Builder home(String value) {
            this.home = value;
            this.homeSet = true;
            return this;
        }
        public Builder item(String value) {
            this.item = value;
            this.itemSet = true;
            return this;
        }
        public FeedLocalHandoffDoneRequest build() { return new FeedLocalHandoffDoneRequest(this); }
    }
}
