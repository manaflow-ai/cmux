// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable url-open-subscribe request. Protocol v12; authority: frontend. */
public final class UrlOpenSubscribeRequest implements WireValue {
    private final List<String> terminalIds;

    private UrlOpenSubscribeRequest(Builder builder) {
        if (!builder.terminalIdsSet) throw new IllegalArgumentException("terminal_ids is required");
        this.terminalIds = List.copyOf(Wire.nonNull(builder.terminalIds, "terminal_ids"));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> terminalIds() { return terminalIds; }

    public static UrlOpenSubscribeRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UrlOpenSubscribeRequest");
        Builder builder = builder();
        Object rawTerminalIds = Wire.required(object, "terminal_ids");
        builder.terminalIds(Wire.array(rawTerminalIds, "UrlOpenSubscribeRequest.terminal_ids", item -> Wire.string(item, "UrlOpenSubscribeRequest.terminal_ids item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "terminal_ids", terminalIds);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UrlOpenSubscribeRequest that)) return false;
        return Objects.equals(terminalIds, that.terminalIds);
    }

    @Override
    public int hashCode() { return Objects.hash(terminalIds); }

    @Override
    public String toString() { return "UrlOpenSubscribeRequest" + toWire(); }

    public static final class Builder {
        private List<String> terminalIds;
        private boolean terminalIdsSet;

        public Builder terminalIds(List<String> value) {
            this.terminalIds = value;
            this.terminalIdsSet = true;
            return this;
        }
        public UrlOpenSubscribeRequest build() { return new UrlOpenSubscribeRequest(this); }
    }
}
