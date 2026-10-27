// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentClijobReceipt implements WireValue {
    private final String cli;
    private final String machine;
    private final AgentCLIJobPath path;
    private final boolean replayed;
    private final String revision;
    private final String session;

    private AgentClijobReceipt(Builder builder) {
        if (!builder.cliSet) throw new IllegalArgumentException("cli is required");
        this.cli = Wire.nonNull(builder.cli, "cli");
        if (!builder.machineSet) throw new IllegalArgumentException("machine is required");
        this.machine = Wire.nonNull(builder.machine, "machine");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
    }

    public static Builder builder() { return new Builder(); }

    public String cli() { return cli; }
    public String machine() { return machine; }
    public AgentCLIJobPath path() { return path; }
    public boolean replayed() { return replayed; }
    public String revision() { return revision; }
    public String session() { return session; }

    public static AgentClijobReceipt fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentClijobReceipt");
        Builder builder = builder();
        Object rawCli = Wire.required(object, "cli");
        builder.cli(Wire.string(rawCli, "AgentClijobReceipt.cli"));
        Object rawMachine = Wire.required(object, "machine");
        builder.machine(Wire.string(rawMachine, "AgentClijobReceipt.machine"));
        Object rawPath = Wire.required(object, "path");
        builder.path(AgentCLIJobPath.fromWire(rawPath));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "AgentClijobReceipt.replayed"));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.string(rawRevision, "AgentClijobReceipt.revision"));
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "AgentClijobReceipt.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cli", cli);
        Wire.put(object, "machine", machine);
        Wire.put(object, "path", path);
        Wire.put(object, "replayed", replayed);
        Wire.put(object, "revision", revision);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentClijobReceipt that)) return false;
        return Objects.equals(cli, that.cli) && Objects.equals(machine, that.machine) && Objects.equals(path, that.path) && Objects.equals(replayed, that.replayed) && Objects.equals(revision, that.revision) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(cli, machine, path, replayed, revision, session); }

    @Override
    public String toString() { return "AgentClijobReceipt" + toWire(); }

    public static final class Builder {
        private String cli;
        private boolean cliSet;
        private String machine;
        private boolean machineSet;
        private AgentCLIJobPath path;
        private boolean pathSet;
        private Boolean replayed;
        private boolean replayedSet;
        private String revision;
        private boolean revisionSet;
        private String session;
        private boolean sessionSet;

        public Builder cli(String value) {
            this.cli = value;
            this.cliSet = true;
            return this;
        }
        public Builder machine(String value) {
            this.machine = value;
            this.machineSet = true;
            return this;
        }
        public Builder path(AgentCLIJobPath value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public Builder revision(String value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public AgentClijobReceipt build() { return new AgentClijobReceipt(this); }
    }
}
