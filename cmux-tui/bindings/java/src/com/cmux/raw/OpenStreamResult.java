// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class OpenStreamResult implements WireValue {
    private final String page;
    private final ClientHelloPageOperations pageOperations;
    private final String relayId;
    private final int stream;

    private OpenStreamResult(Builder builder) {
        if (!builder.pageSet) throw new IllegalArgumentException("page is required");
        this.page = Wire.nonNull(builder.page, "page");
        if (!builder.pageOperationsSet) throw new IllegalArgumentException("page_operations is required");
        this.pageOperations = Wire.nonNull(builder.pageOperations, "page_operations");
        if (!builder.relayIdSet) throw new IllegalArgumentException("relay_id is required");
        this.relayId = Wire.nonNull(builder.relayId, "relay_id");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public String page() { return page; }
    public ClientHelloPageOperations pageOperations() { return pageOperations; }
    public String relayId() { return relayId; }
    public int stream() { return stream; }

    public static OpenStreamResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "OpenStreamResult");
        Builder builder = builder();
        Object rawPage = Wire.required(object, "page");
        builder.page(Wire.string(rawPage, "OpenStreamResult.page"));
        Object rawPageOperations = Wire.required(object, "page_operations");
        builder.pageOperations(ClientHelloPageOperations.fromWire(rawPageOperations));
        Object rawRelayId = Wire.required(object, "relay_id");
        builder.relayId(Wire.string(rawRelayId, "OpenStreamResult.relay_id"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "OpenStreamResult.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "page", page);
        Wire.put(object, "page_operations", pageOperations);
        Wire.put(object, "relay_id", relayId);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof OpenStreamResult that)) return false;
        return Objects.equals(page, that.page) && Objects.equals(pageOperations, that.pageOperations) && Objects.equals(relayId, that.relayId) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(page, pageOperations, relayId, stream); }

    @Override
    public String toString() { return "OpenStreamResult" + toWire(); }

    public static final class Builder {
        private String page;
        private boolean pageSet;
        private ClientHelloPageOperations pageOperations;
        private boolean pageOperationsSet;
        private String relayId;
        private boolean relayIdSet;
        private Integer stream;
        private boolean streamSet;

        public Builder page(String value) {
            this.page = value;
            this.pageSet = true;
            return this;
        }
        public Builder pageOperations(ClientHelloPageOperations value) {
            this.pageOperations = value;
            this.pageOperationsSet = true;
            return this;
        }
        public Builder relayId(String value) {
            this.relayId = value;
            this.relayIdSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public OpenStreamResult build() { return new OpenStreamResult(this); }
    }
}
