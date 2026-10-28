// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClistoredIntent implements WireValue {
    private final String cli;
    private final String key;
    private final String machine;
    private final List<String> profiles;
    private final AgentCLIJobReceipt receipt;
    private final String rootKey;
    private final String session;

    private AgentClistoredIntent(Builder builder) {
        if (!builder.cliSet) throw new IllegalArgumentException("cli is required");
        this.cli = Wire.nonNull(builder.cli, "cli");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        if (!builder.profilesSet) throw new IllegalArgumentException("profiles is required");
        this.profiles = List.copyOf(Wire.nonNull(builder.profiles, "profiles"));
        if (!builder.receiptSet) throw new IllegalArgumentException("receipt is required");
        this.receipt = builder.receipt;
        if (!builder.rootKeySet) throw new IllegalArgumentException("root_key is required");
        this.rootKey = Wire.nonNull(builder.rootKey, "root_key");
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
    }

    public static Builder builder() { return new Builder(); }

    public String cli() { return cli; }
    public String key() { return key; }
    public String machine() { return machine; }
    public List<String> profiles() { return profiles; }
    public AgentCLIJobReceipt receipt() { return receipt; }
    public String rootKey() { return rootKey; }
    public String session() { return session; }

    public static AgentClistoredIntent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClistoredIntent");
        Builder builder = builder();
        Object rawCli = Wire.required(object, "cli");
        builder.cli(Wire.string(rawCli, "AgentClistoredIntent.cli"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "AgentClistoredIntent.key"));
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentClistoredIntent.machine"));
        Object rawProfiles = Wire.required(object, "profiles");
        builder.profiles(Wire.array(rawProfiles, "AgentClistoredIntent.profiles", item -> Wire.string(item, "AgentClistoredIntent.profiles item")));
        Object rawReceipt = Wire.required(object, "receipt");
        builder.receipt(rawReceipt == null ? null : AgentCLIJobReceipt.fromWire(rawReceipt));
        Object rawRootKey = Wire.required(object, "root_key");
        builder.rootKey(Wire.string(rawRootKey, "AgentClistoredIntent.root_key"));
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "AgentClistoredIntent.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cli", cli);
        Wire.put(object, "key", key);
        Wire.put(object, "machine", machine);
        Wire.put(object, "profiles", profiles);
        Wire.put(object, "receipt", receipt);
        Wire.put(object, "root_key", rootKey);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClistoredIntent that)) return false;
        return Objects.equals(cli, that.cli) && Objects.equals(key, that.key) && Objects.equals(machine, that.machine) && Objects.equals(profiles, that.profiles) && Objects.equals(receipt, that.receipt) && Objects.equals(rootKey, that.rootKey) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(cli, key, machine, profiles, receipt, rootKey, session); }

    @Override
    public String toString() { return "AgentClistoredIntent" + toWire(); }

    public static final class Builder {
        private String cli;
        private boolean cliSet;
        private String key;
        private boolean keySet;
        private String machine;
        private boolean machineSet;
        private List<String> profiles;
        private boolean profilesSet;
        private AgentCLIJobReceipt receipt;
        private boolean receiptSet;
        private String rootKey;
        private boolean rootKeySet;
        private String session;
        private boolean sessionSet;

        public Builder cli(String value) {
            this.cli = value;
            this.cliSet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public Builder profiles(List<String> value) {
            this.profiles = value;
            this.profilesSet = true;
            return this;
        }
        public Builder receipt(AgentCLIJobReceipt value) {
            this.receipt = value;
            this.receiptSet = true;
            return this;
        }
        public Builder rootKey(String value) {
            this.rootKey = value;
            this.rootKeySet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public AgentClistoredIntent build() { return new AgentClistoredIntent(this); }
    }
}
