// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frontend-browser-tab-close-settled event. Protocol v12; streams: control. */
public final class FrontendBrowserTabCloseSettledEvent implements WireValue, ProtocolEvent {
    private final FrontendBrowserTabCloseSettledEventOutcome outcome;
    private final String requestId;
    private final UInt64 surface;

    private FrontendBrowserTabCloseSettledEvent(Builder builder) {
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public FrontendBrowserTabCloseSettledEventOutcome outcome() { return outcome; }
    public String requestId() { return requestId; }
    public UInt64 surface() { return surface; }
    @Override public String event() { return "frontend-browser-tab-close-settled"; }

    public static FrontendBrowserTabCloseSettledEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendBrowserTabCloseSettledEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "frontend-browser-tab-close-settled", "FrontendBrowserTabCloseSettledEvent.event");
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(FrontendBrowserTabCloseSettledEventOutcome.fromWire(rawOutcome));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "FrontendBrowserTabCloseSettledEvent.request_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "FrontendBrowserTabCloseSettledEvent.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "frontend-browser-tab-close-settled");
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendBrowserTabCloseSettledEvent that)) return false;
        return Objects.equals(outcome, that.outcome) && Objects.equals(requestId, that.requestId) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(outcome, requestId, surface); }

    @Override
    public String toString() { return "FrontendBrowserTabCloseSettledEvent" + toWire(); }

    public static final class Builder {
        private FrontendBrowserTabCloseSettledEventOutcome outcome;
        private boolean outcomeSet;
        private String requestId;
        private boolean requestIdSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder outcome(FrontendBrowserTabCloseSettledEventOutcome value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public FrontendBrowserTabCloseSettledEvent build() { return new FrontendBrowserTabCloseSettledEvent(this); }
    }
}
