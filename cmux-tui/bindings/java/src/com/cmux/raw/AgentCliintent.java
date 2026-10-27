// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentCliintent implements WireValue {
    private final String cli;
    private final String key;
    private final String machine;
    private final List<String> profiles;
    private final String rootKey;
    private final String session;

    private AgentCliintent(Builder builder) {
        if (!builder.cliSet) throw new IllegalArgumentException("cli is required");
        this.cli = Wire.nonNull(builder.cli, "cli");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        if (!builder.profilesSet) throw new IllegalArgumentException("profiles is required");
        this.profiles = List.copyOf(Wire.nonNull(builder.profiles, "profiles"));
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
    public String rootKey() { return rootKey; }
    public String session() { return session; }

    public static AgentCliintent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliintent");
        Builder builder = builder();
        Object rawCli = Wire.required(object, "cli");
        builder.cli(Wire.string(rawCli, "AgentCliintent.cli"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "AgentCliintent.key"));
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentCliintent.machine"));
        Object rawProfiles = Wire.required(object, "profiles");
        builder.profiles(Wire.array(rawProfiles, "AgentCliintent.profiles", item -> Wire.string(item, "AgentCliintent.profiles item")));
        Object rawRootKey = Wire.required(object, "root_key");
        builder.rootKey(Wire.string(rawRootKey, "AgentCliintent.root_key"));
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "AgentCliintent.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cli", cli);
        Wire.put(object, "key", key);
        Wire.put(object, "machine", machine);
        Wire.put(object, "profiles", profiles);
        Wire.put(object, "root_key", rootKey);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliintent that)) return false;
        return Objects.equals(cli, that.cli) && Objects.equals(key, that.key) && Objects.equals(machine, that.machine) && Objects.equals(profiles, that.profiles) && Objects.equals(rootKey, that.rootKey) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(cli, key, machine, profiles, rootKey, session); }

    @Override
    public String toString() { return "AgentCliintent" + toWire(); }

    public static final class Builder {
        private String cli;
        private boolean cliSet;
        private String key;
        private boolean keySet;
        private String machine;
        private boolean machineSet;
        private List<String> profiles;
        private boolean profilesSet;
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
        public AgentCliintent build() { return new AgentCliintent(this); }
    }
}
