// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientAttentionResult implements WireValue {
    /** Some connected client has its app active. */
    private final boolean appActive;
    private final List<ClientAttentionRecord> clients;
    /** Present when surface was given. */
    private final Field<ClientAttentionTab> tabAttention;

    private ClientAttentionResult(Builder builder) {
        if (!builder.appActiveSet) throw new IllegalArgumentException("app_active is required");
        this.appActive = builder.appActive;
        if (!builder.clientsSet) throw new IllegalArgumentException("clients is required");
        this.clients = List.copyOf(Wire.nonNull(builder.clients, "clients"));
        this.tabAttention = builder.tabAttention;
    }

    public static Builder builder() { return new Builder(); }

    public boolean appActive() { return appActive; }
    public List<ClientAttentionRecord> clients() { return clients; }
    public Field<ClientAttentionTab> tabAttention() { return tabAttention; }

    public static ClientAttentionResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionResult");
        Builder builder = builder();
        Object rawAppActive = Wire.required(object, "app_active");
        builder.appActive(Wire.bool(rawAppActive, "ClientAttentionResult.app_active"));
        Object rawClients = Wire.required(object, "clients");
        builder.clients(Wire.array(rawClients, "ClientAttentionResult.clients", item -> ClientAttentionRecord.fromWire(item)));
        Object rawTabAttention = Wire.optional(object, "tab_attention");
        if (!Wire.isMissing(rawTabAttention)) {
            builder.tabAttention(ClientAttentionTab.fromWire(rawTabAttention));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app_active", appActive);
        Wire.put(object, "clients", clients);
        Wire.put(object, "tab_attention", tabAttention);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionResult that)) return false;
        return Objects.equals(appActive, that.appActive) && Objects.equals(clients, that.clients) && Objects.equals(tabAttention, that.tabAttention);
    }

    @Override
    public int hashCode() { return Objects.hash(appActive, clients, tabAttention); }

    @Override
    public String toString() { return "ClientAttentionResult" + toWire(); }

    public static final class Builder {
        private Boolean appActive;
        private boolean appActiveSet;
        private List<ClientAttentionRecord> clients;
        private boolean clientsSet;
        private Field<ClientAttentionTab> tabAttention = Field.omitted();

        public Builder appActive(boolean value) {
            this.appActive = value;
            this.appActiveSet = true;
            return this;
        }
        public Builder clients(List<ClientAttentionRecord> value) {
            this.clients = value;
            this.clientsSet = true;
            return this;
        }
        public Builder tabAttention(ClientAttentionTab value) {
            this.tabAttention = Field.of(value);
            return this;
        }
        public ClientAttentionResult build() { return new ClientAttentionResult(this); }
    }
}
