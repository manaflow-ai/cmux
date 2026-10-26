// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable server-threads request. Protocol v12; authority: local-admin. */
public final class ServerThreadsRequest implements WireValue {

    private ServerThreadsRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static ServerThreadsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerThreadsRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerThreadsRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "ServerThreadsRequest" + toWire(); }

    public static final class Builder {

        public ServerThreadsRequest build() { return new ServerThreadsRequest(this); }
    }
}
