// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-bookmarks request. Protocol v12; authority: control. */
public final class ListBookmarksRequest implements WireValue {
    private final String browserProfileId;

    private ListBookmarksRequest(Builder builder) {
        if (!builder.browserProfileIdSet) throw new IllegalArgumentException("browser_profile_id is required");
        this.browserProfileId = Wire.nonNull(builder.browserProfileId, "browser_profile_id");
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfileId() { return browserProfileId; }

    public static ListBookmarksRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListBookmarksRequest");
        Builder builder = builder();
        Object rawBrowserProfileId = Wire.required(object, "browser_profile_id");
        builder.browserProfileId(Wire.string(rawBrowserProfileId, "ListBookmarksRequest.browser_profile_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile_id", browserProfileId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListBookmarksRequest that)) return false;
        return Objects.equals(browserProfileId, that.browserProfileId);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfileId); }

    @Override
    public String toString() { return "ListBookmarksRequest" + toWire(); }

    public static final class Builder {
        private String browserProfileId;
        private boolean browserProfileIdSet;

        public Builder browserProfileId(String value) {
            this.browserProfileId = value;
            this.browserProfileIdSet = true;
            return this;
        }
        public ListBookmarksRequest build() { return new ListBookmarksRequest(this); }
    }
}
