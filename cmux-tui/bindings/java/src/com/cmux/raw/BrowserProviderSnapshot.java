// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserProviderSnapshot implements WireValue {
    private final Field<BrowserProviderAuthentication> authentication;
    private final boolean available;
    private final Field<UInt64> clients;
    private final Field<String> endpoint;
    private final Field<String> providerId;
    private final UInt64 revision;
    private final List<BrowserProviderTarget> targets;

    private BrowserProviderSnapshot(Builder builder) {
        this.authentication = builder.authentication;
        if (!builder.availableSet) throw new IllegalArgumentException("available is required");
        this.available = builder.available;
        this.clients = builder.clients;
        this.endpoint = builder.endpoint;
        this.providerId = builder.providerId;
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.targetsSet) throw new IllegalArgumentException("targets is required");
        this.targets = List.copyOf(Wire.nonNull(builder.targets, "targets"));
    }

    public static Builder builder() { return new Builder(); }

    public Field<BrowserProviderAuthentication> authentication() { return authentication; }
    public boolean available() { return available; }
    public Field<UInt64> clients() { return clients; }
    public Field<String> endpoint() { return endpoint; }
    public Field<String> providerId() { return providerId; }
    public UInt64 revision() { return revision; }
    public List<BrowserProviderTarget> targets() { return targets; }

    public static BrowserProviderSnapshot fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserProviderSnapshot");
        Builder builder = builder();
        Object rawAuthentication = Wire.optional(object, "authentication");
        if (!Wire.isMissing(rawAuthentication)) {
            builder.authentication(BrowserProviderAuthentication.fromWire(rawAuthentication));
        }
        Object rawAvailable = Wire.required(object, "available");
        builder.available(Wire.bool(rawAvailable, "BrowserProviderSnapshot.available"));
        Object rawClients = Wire.optional(object, "clients");
        if (!Wire.isMissing(rawClients)) {
            builder.clients(Wire.uint64(rawClients, "BrowserProviderSnapshot.clients"));
        }
        Object rawEndpoint = Wire.optional(object, "endpoint");
        if (!Wire.isMissing(rawEndpoint)) {
            builder.endpoint(Wire.string(rawEndpoint, "BrowserProviderSnapshot.endpoint"));
        }
        Object rawProviderId = Wire.optional(object, "provider_id");
        if (!Wire.isMissing(rawProviderId)) {
            builder.providerId(Wire.string(rawProviderId, "BrowserProviderSnapshot.provider_id"));
        }
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "BrowserProviderSnapshot.revision"));
        Object rawTargets = Wire.required(object, "targets");
        builder.targets(Wire.array(rawTargets, "BrowserProviderSnapshot.targets", item -> BrowserProviderTarget.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authentication", authentication);
        Wire.put(object, "available", available);
        Wire.put(object, "clients", clients);
        Wire.put(object, "endpoint", endpoint);
        Wire.put(object, "provider_id", providerId);
        Wire.put(object, "revision", revision);
        Wire.put(object, "targets", targets);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserProviderSnapshot that)) return false;
        return Objects.equals(authentication, that.authentication) && Objects.equals(available, that.available) && Objects.equals(clients, that.clients) && Objects.equals(endpoint, that.endpoint) && Objects.equals(providerId, that.providerId) && Objects.equals(revision, that.revision) && Objects.equals(targets, that.targets);
    }

    @Override
    public int hashCode() { return Objects.hash(authentication, available, clients, endpoint, providerId, revision, targets); }

    @Override
    public String toString() { return "BrowserProviderSnapshot" + toWire(); }

    public static final class Builder {
        private Field<BrowserProviderAuthentication> authentication = Field.omitted();
        private Boolean available;
        private boolean availableSet;
        private Field<UInt64> clients = Field.omitted();
        private Field<String> endpoint = Field.omitted();
        private Field<String> providerId = Field.omitted();
        private UInt64 revision;
        private boolean revisionSet;
        private List<BrowserProviderTarget> targets;
        private boolean targetsSet;

        public Builder authentication(BrowserProviderAuthentication value) {
            this.authentication = Field.of(value);
            return this;
        }
        public Builder available(boolean value) {
            this.available = value;
            this.availableSet = true;
            return this;
        }
        public Builder clients(UInt64 value) {
            this.clients = Field.of(value);
            return this;
        }
        public Builder endpoint(String value) {
            this.endpoint = Field.of(value);
            return this;
        }
        public Builder providerId(String value) {
            this.providerId = Field.of(value);
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder targets(List<BrowserProviderTarget> value) {
            this.targets = value;
            this.targetsSet = true;
            return this;
        }
        public BrowserProviderSnapshot build() { return new BrowserProviderSnapshot(this); }
    }
}
