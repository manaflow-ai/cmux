// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-hello request. Protocol v12; authority: local-admin. */
public final class ClientHelloRequest implements WireValue {
    private final Field<ClientHelloFeatures> features;
    private final Field<String> installId;
    private final Field<String> page;
    private final Field<String> proof;
    private final Field<String> role;

    private ClientHelloRequest(Builder builder) {
        this.features = builder.features;
        this.installId = builder.installId;
        this.page = builder.page;
        this.proof = builder.proof;
        this.role = builder.role;
    }

    public static Builder builder() { return new Builder(); }

    public Field<ClientHelloFeatures> features() { return features; }
    public Field<String> installId() { return installId; }
    public Field<String> page() { return page; }
    public Field<String> proof() { return proof; }
    public Field<String> role() { return role; }

    public static ClientHelloRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloRequest");
        Builder builder = builder();
        Object rawFeatures = Wire.optional(object, "features");
        if (!Wire.isMissing(rawFeatures)) {
            builder.features(rawFeatures == null ? null : ClientHelloFeatures.fromWire(rawFeatures));
        }
        Object rawInstallId = Wire.optional(object, "install_id");
        if (!Wire.isMissing(rawInstallId)) {
            builder.installId(Wire.string(rawInstallId, "ClientHelloRequest.install_id"));
        }
        Object rawPage = Wire.optional(object, "page");
        if (!Wire.isMissing(rawPage)) {
            builder.page(rawPage == null ? null : Wire.string(rawPage, "ClientHelloRequest.page"));
        }
        Object rawProof = Wire.optional(object, "proof");
        if (!Wire.isMissing(rawProof)) {
            builder.proof(Wire.string(rawProof, "ClientHelloRequest.proof"));
        }
        Object rawRole = Wire.optional(object, "role");
        if (!Wire.isMissing(rawRole)) {
            builder.role(Wire.string(rawRole, "ClientHelloRequest.role"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "features", features);
        Wire.put(object, "install_id", installId);
        Wire.put(object, "page", page);
        Wire.put(object, "proof", proof);
        Wire.put(object, "role", role);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloRequest that)) return false;
        return Objects.equals(features, that.features) && Objects.equals(installId, that.installId) && Objects.equals(page, that.page) && Objects.equals(proof, that.proof) && Objects.equals(role, that.role);
    }

    @Override
    public int hashCode() { return Objects.hash(features, installId, page, proof, role); }

    @Override
    public String toString() { return "ClientHelloRequest" + toWire(); }

    public static final class Builder {
        private Field<ClientHelloFeatures> features = Field.omitted();
        private Field<String> installId = Field.omitted();
        private Field<String> page = Field.omitted();
        private Field<String> proof = Field.omitted();
        private Field<String> role = Field.omitted();

        public Builder features(ClientHelloFeatures value) {
            this.features = Field.ofNullable(value);
            return this;
        }
        public Builder installId(String value) {
            this.installId = Field.of(value);
            return this;
        }
        public Builder page(String value) {
            this.page = Field.ofNullable(value);
            return this;
        }
        public Builder proof(String value) {
            this.proof = Field.of(value);
            return this;
        }
        public Builder role(String value) {
            this.role = Field.of(value);
            return this;
        }
        public ClientHelloRequest build() { return new ClientHelloRequest(this); }
    }
}
