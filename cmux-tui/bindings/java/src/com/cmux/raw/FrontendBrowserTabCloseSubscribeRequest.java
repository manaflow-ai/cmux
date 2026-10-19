// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frontend-browser-tab-close-subscribe request. Protocol v12; authority: control. */
public final class FrontendBrowserTabCloseSubscribeRequest implements WireValue {
    /** The install id the app puts on new-frontend-browser-tab {owner}; 1-128 characters of A-Z a-z 0-9 _ -. */
    private final String owner;

    private FrontendBrowserTabCloseSubscribeRequest(Builder builder) {
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
    }

    public static Builder builder() { return new Builder(); }

    public String owner() { return owner; }

    public static FrontendBrowserTabCloseSubscribeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendBrowserTabCloseSubscribeRequest");
        Builder builder = builder();
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "FrontendBrowserTabCloseSubscribeRequest.owner"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "owner", owner);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendBrowserTabCloseSubscribeRequest that)) return false;
        return Objects.equals(owner, that.owner);
    }

    @Override
    public int hashCode() { return Objects.hash(owner); }

    @Override
    public String toString() { return "FrontendBrowserTabCloseSubscribeRequest" + toWire(); }

    public static final class Builder {
        private String owner;
        private boolean ownerSet;

        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public FrontendBrowserTabCloseSubscribeRequest build() { return new FrontendBrowserTabCloseSubscribeRequest(this); }
    }
}
