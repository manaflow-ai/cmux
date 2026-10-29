// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientHelloResult implements WireValue {
    private final String connectionId;
    private final Field<ClientHelloFeatureReport> features;
    private final Field<String> installId;
    private final Field<String> nonce;
    private final Field<String> page;
    private final Field<List<String>> pageEvents;
    private final Field<ClientHelloPageOperations> pageOperations;
    private final Field<Boolean> pageStreams;
    private final boolean userOriginAllowed;
    private final Field<Boolean> verified;

    private ClientHelloResult(Builder builder) {
        if (!builder.connectionIdSet) throw new IllegalArgumentException("connection_id is required");
        this.connectionId = Wire.nonNull(builder.connectionId, "connection_id");
        this.features = builder.features;
        this.installId = builder.installId;
        this.nonce = builder.nonce;
        this.page = builder.page;
        this.pageEvents = builder.pageEvents.map(value -> List.copyOf(value));
        this.pageOperations = builder.pageOperations;
        this.pageStreams = builder.pageStreams;
        if (!builder.userOriginAllowedSet) throw new IllegalArgumentException("user_origin_allowed is required");
        this.userOriginAllowed = builder.userOriginAllowed;
        this.verified = builder.verified;
    }

    public static Builder builder() { return new Builder(); }

    public String connectionId() { return connectionId; }
    public Field<ClientHelloFeatureReport> features() { return features; }
    public Field<String> installId() { return installId; }
    public Field<String> nonce() { return nonce; }
    public Field<String> page() { return page; }
    public Field<List<String>> pageEvents() { return pageEvents; }
    public Field<ClientHelloPageOperations> pageOperations() { return pageOperations; }
    public Field<Boolean> pageStreams() { return pageStreams; }
    public boolean userOriginAllowed() { return userOriginAllowed; }
    public Field<Boolean> verified() { return verified; }

    public static ClientHelloResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloResult");
        Builder builder = builder();
        Object rawConnectionId = Wire.required(object, "connection_id");
        builder.connectionId(Wire.string(rawConnectionId, "ClientHelloResult.connection_id"));
        Object rawFeatures = Wire.optional(object, "features");
        if (!Wire.isMissing(rawFeatures)) {
            builder.features(ClientHelloFeatureReport.fromWire(rawFeatures));
        }
        Object rawInstallId = Wire.optional(object, "install_id");
        if (!Wire.isMissing(rawInstallId)) {
            builder.installId(Wire.string(rawInstallId, "ClientHelloResult.install_id"));
        }
        Object rawNonce = Wire.optional(object, "nonce");
        if (!Wire.isMissing(rawNonce)) {
            builder.nonce(Wire.string(rawNonce, "ClientHelloResult.nonce"));
        }
        Object rawPage = Wire.optional(object, "page");
        if (!Wire.isMissing(rawPage)) {
            builder.page(Wire.string(rawPage, "ClientHelloResult.page"));
        }
        Object rawPageEvents = Wire.optional(object, "page_events");
        if (!Wire.isMissing(rawPageEvents)) {
            builder.pageEvents(Wire.array(rawPageEvents, "ClientHelloResult.page_events", item -> Wire.string(item, "ClientHelloResult.page_events item")));
        }
        Object rawPageOperations = Wire.optional(object, "page_operations");
        if (!Wire.isMissing(rawPageOperations)) {
            builder.pageOperations(ClientHelloPageOperations.fromWire(rawPageOperations));
        }
        Object rawPageStreams = Wire.optional(object, "page_streams");
        if (!Wire.isMissing(rawPageStreams)) {
            builder.pageStreams(ProtocolSupport.literal(rawPageStreams, true, "ClientHelloResult.page_streams"));
        }
        Object rawUserOriginAllowed = Wire.required(object, "user_origin_allowed");
        builder.userOriginAllowed(Wire.bool(rawUserOriginAllowed, "ClientHelloResult.user_origin_allowed"));
        Object rawVerified = Wire.optional(object, "verified");
        if (!Wire.isMissing(rawVerified)) {
            builder.verified(ProtocolSupport.literal(rawVerified, true, "ClientHelloResult.verified"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "connection_id", connectionId);
        Wire.put(object, "features", features);
        Wire.put(object, "install_id", installId);
        Wire.put(object, "nonce", nonce);
        Wire.put(object, "page", page);
        Wire.put(object, "page_events", pageEvents);
        Wire.put(object, "page_operations", pageOperations);
        Wire.put(object, "page_streams", pageStreams);
        Wire.put(object, "user_origin_allowed", userOriginAllowed);
        Wire.put(object, "verified", verified);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloResult that)) return false;
        return Objects.equals(connectionId, that.connectionId) && Objects.equals(features, that.features) && Objects.equals(installId, that.installId) && Objects.equals(nonce, that.nonce) && Objects.equals(page, that.page) && Objects.equals(pageEvents, that.pageEvents) && Objects.equals(pageOperations, that.pageOperations) && Objects.equals(pageStreams, that.pageStreams) && Objects.equals(userOriginAllowed, that.userOriginAllowed) && Objects.equals(verified, that.verified);
    }

    @Override
    public int hashCode() { return Objects.hash(connectionId, features, installId, nonce, page, pageEvents, pageOperations, pageStreams, userOriginAllowed, verified); }

    @Override
    public String toString() { return "ClientHelloResult" + toWire(); }

    public static final class Builder {
        private String connectionId;
        private boolean connectionIdSet;
        private Field<ClientHelloFeatureReport> features = Field.omitted();
        private Field<String> installId = Field.omitted();
        private Field<String> nonce = Field.omitted();
        private Field<String> page = Field.omitted();
        private Field<List<String>> pageEvents = Field.omitted();
        private Field<ClientHelloPageOperations> pageOperations = Field.omitted();
        private Field<Boolean> pageStreams = Field.omitted();
        private Boolean userOriginAllowed;
        private boolean userOriginAllowedSet;
        private Field<Boolean> verified = Field.omitted();

        public Builder connectionId(String value) {
            this.connectionId = value;
            this.connectionIdSet = true;
            return this;
        }
        public Builder features(ClientHelloFeatureReport value) {
            this.features = Field.of(value);
            return this;
        }
        public Builder installId(String value) {
            this.installId = Field.of(value);
            return this;
        }
        public Builder nonce(String value) {
            this.nonce = Field.of(value);
            return this;
        }
        public Builder page(String value) {
            this.page = Field.of(value);
            return this;
        }
        public Builder pageEvents(List<String> value) {
            this.pageEvents = Field.of(value);
            return this;
        }
        public Builder pageOperations(ClientHelloPageOperations value) {
            this.pageOperations = Field.of(value);
            return this;
        }
        public Builder pageStreams(Boolean value) {
            ProtocolSupport.literal(value, true, "ClientHelloResult.page_streams");
            this.pageStreams = Field.of(value);
            return this;
        }
        public Builder userOriginAllowed(boolean value) {
            this.userOriginAllowed = value;
            this.userOriginAllowedSet = true;
            return this;
        }
        public Builder verified(Boolean value) {
            ProtocolSupport.literal(value, true, "ClientHelloResult.verified");
            this.verified = Field.of(value);
            return this;
        }
        public ClientHelloResult build() { return new ClientHelloResult(this); }
    }
}
