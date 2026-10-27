// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-cli-update-job-resolve request. Protocol v12; authority: local-admin. */
public final class AgentCliUpdateJobResolveRequest implements WireValue {
    private final String cli;
    private final String expectedMachineId;
    private final String expectedSessionId;
    private final String idempotencyKey;

    private AgentCliUpdateJobResolveRequest(Builder builder) {
        if (!builder.cliSet) throw new IllegalArgumentException("cli is required");
        this.cli = Wire.nonNull(builder.cli, "cli");
        if (!builder.expectedMachineIdSet) throw new IllegalArgumentException("expected_machine_id is required");
        this.expectedMachineId = Wire.nonNull(builder.expectedMachineId, "expected_machine_id");
        if (!builder.expectedSessionIdSet) throw new IllegalArgumentException("expected_session_id is required");
        this.expectedSessionId = Wire.nonNull(builder.expectedSessionId, "expected_session_id");
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
    }

    public static Builder builder() { return new Builder(); }

    public String cli() { return cli; }
    public String expectedMachineId() { return expectedMachineId; }
    public String expectedSessionId() { return expectedSessionId; }
    public String idempotencyKey() { return idempotencyKey; }

    public static AgentCliUpdateJobResolveRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliUpdateJobResolveRequest");
        Builder builder = builder();
        Object rawCli = Wire.required(object, "cli");
        builder.cli(Wire.string(rawCli, "AgentCliUpdateJobResolveRequest.cli"));
        Object rawExpectedMachineId = Wire.required(object, "expected_machine_id");
        builder.expectedMachineId(Wire.string(rawExpectedMachineId, "AgentCliUpdateJobResolveRequest.expected_machine_id"));
        Object rawExpectedSessionId = Wire.required(object, "expected_session_id");
        builder.expectedSessionId(Wire.string(rawExpectedSessionId, "AgentCliUpdateJobResolveRequest.expected_session_id"));
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "AgentCliUpdateJobResolveRequest.idempotency_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cli", cli);
        Wire.put(object, "expected_machine_id", expectedMachineId);
        Wire.put(object, "expected_session_id", expectedSessionId);
        Wire.put(object, "idempotency_key", idempotencyKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliUpdateJobResolveRequest that)) return false;
        return Objects.equals(cli, that.cli) && Objects.equals(expectedMachineId, that.expectedMachineId) && Objects.equals(expectedSessionId, that.expectedSessionId) && Objects.equals(idempotencyKey, that.idempotencyKey);
    }

    @Override
    public int hashCode() { return Objects.hash(cli, expectedMachineId, expectedSessionId, idempotencyKey); }

    @Override
    public String toString() { return "AgentCliUpdateJobResolveRequest" + toWire(); }

    public static final class Builder {
        private String cli;
        private boolean cliSet;
        private String expectedMachineId;
        private boolean expectedMachineIdSet;
        private String expectedSessionId;
        private boolean expectedSessionIdSet;
        private String idempotencyKey;
        private boolean idempotencyKeySet;

        public Builder cli(String value) {
            this.cli = value;
            this.cliSet = true;
            return this;
        }
        public Builder expectedMachineId(String value) {
            this.expectedMachineId = value;
            this.expectedMachineIdSet = true;
            return this;
        }
        public Builder expectedSessionId(String value) {
            this.expectedSessionId = value;
            this.expectedSessionIdSet = true;
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = value;
            this.idempotencyKeySet = true;
            return this;
        }
        public AgentCliUpdateJobResolveRequest build() { return new AgentCliUpdateJobResolveRequest(this); }
    }
}
