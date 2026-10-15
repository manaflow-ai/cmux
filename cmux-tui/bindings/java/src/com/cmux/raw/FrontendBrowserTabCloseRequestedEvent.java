// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable frontend-browser-tab-close-requested event. Protocol v12; streams: control. */
public final class FrontendBrowserTabCloseRequestedEvent implements WireValue, ProtocolEvent {
    /** The tab record's owner install id that this connection subscribed for. */
    private final String owner;
    private final CloseReason reason;
    private final String requestId;
    private final UInt64 surface;
    private final String tabResourceId;

    private FrontendBrowserTabCloseRequestedEvent(Builder builder) {
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = builder.reason;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.tabResourceIdSet) throw new IllegalArgumentException("tab_resource_id is required");
        this.tabResourceId = builder.tabResourceId;
    }

    public static Builder builder() { return new Builder(); }

    public String owner() { return owner; }
    public CloseReason reason() { return reason; }
    public String requestId() { return requestId; }
    public UInt64 surface() { return surface; }
    public String tabResourceId() { return tabResourceId; }
    @Override public String event() { return "frontend-browser-tab-close-requested"; }

    public static FrontendBrowserTabCloseRequestedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendBrowserTabCloseRequestedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "frontend-browser-tab-close-requested", "FrontendBrowserTabCloseRequestedEvent.event");
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "FrontendBrowserTabCloseRequestedEvent.owner"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(rawReason == null ? null : CloseReason.fromWire(rawReason));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "FrontendBrowserTabCloseRequestedEvent.request_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "FrontendBrowserTabCloseRequestedEvent.surface"));
        Object rawTabResourceId = Wire.required(object, "tab_resource_id");
        builder.tabResourceId(rawTabResourceId == null ? null : Wire.string(rawTabResourceId, "FrontendBrowserTabCloseRequestedEvent.tab_resource_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "frontend-browser-tab-close-requested");
        Wire.put(object, "owner", owner);
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tab_resource_id", tabResourceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendBrowserTabCloseRequestedEvent that)) return false;
        return Objects.equals(owner, that.owner) && Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(surface, that.surface) && Objects.equals(tabResourceId, that.tabResourceId);
    }

    @Override
    public int hashCode() { return Objects.hash(owner, reason, requestId, surface, tabResourceId); }

    @Override
    public String toString() { return "FrontendBrowserTabCloseRequestedEvent" + toWire(); }

    public static final class Builder {
        private String owner;
        private boolean ownerSet;
        private CloseReason reason;
        private boolean reasonSet;
        private String requestId;
        private boolean requestIdSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String tabResourceId;
        private boolean tabResourceIdSet;

        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public Builder reason(CloseReason value) {
            this.reason = value;
            this.reasonSet = true;
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
        public Builder tabResourceId(String value) {
            this.tabResourceId = value;
            this.tabResourceIdSet = true;
            return this;
        }
        public FrontendBrowserTabCloseRequestedEvent build() { return new FrontendBrowserTabCloseRequestedEvent(this); }
    }
}
