// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MintTerminalRendererResult implements WireValue {
    private final String endpoint;
    private final String incarnation;
    private final int protocolVersion;
    private final long rights;
    private final String terminalId;
    private final String token;
    private final UInt64 ttlMs;

    private MintTerminalRendererResult(Builder builder) {
        if (!builder.endpointSet) throw new IllegalArgumentException("endpoint is required");
        this.endpoint = Wire.nonNull(builder.endpoint, "endpoint");
        if (!builder.incarnationSet) throw new IllegalArgumentException("incarnation is required");
        this.incarnation = Wire.nonNull(builder.incarnation, "incarnation");
        if (!builder.protocolVersionSet) throw new IllegalArgumentException("protocol_version is required");
        this.protocolVersion = builder.protocolVersion;
        if (!builder.rightsSet) throw new IllegalArgumentException("rights is required");
        this.rights = builder.rights;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.tokenSet) throw new IllegalArgumentException("token is required");
        this.token = Wire.nonNull(builder.token, "token");
        if (!builder.ttlMsSet) throw new IllegalArgumentException("ttl_ms is required");
        this.ttlMs = Wire.nonNull(builder.ttlMs, "ttl_ms");
    }

    public static Builder builder() { return new Builder(); }

    public String endpoint() { return endpoint; }
    public String incarnation() { return incarnation; }
    public int protocolVersion() { return protocolVersion; }
    public long rights() { return rights; }
    public String terminalId() { return terminalId; }
    public String token() { return token; }
    public UInt64 ttlMs() { return ttlMs; }

    public static MintTerminalRendererResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MintTerminalRendererResult");
        Builder builder = builder();
        Object rawEndpoint = Wire.required(object, "endpoint");
        builder.endpoint(Wire.string(rawEndpoint, "MintTerminalRendererResult.endpoint"));
        Object rawIncarnation = Wire.required(object, "incarnation");
        builder.incarnation(Wire.string(rawIncarnation, "MintTerminalRendererResult.incarnation"));
        Object rawProtocolVersion = Wire.required(object, "protocol_version");
        builder.protocolVersion(Wire.uint16(rawProtocolVersion, "MintTerminalRendererResult.protocol_version"));
        Object rawRights = Wire.required(object, "rights");
        builder.rights(Wire.uint32(rawRights, "MintTerminalRendererResult.rights"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "MintTerminalRendererResult.terminal_id"));
        Object rawToken = Wire.required(object, "token");
        builder.token(Wire.string(rawToken, "MintTerminalRendererResult.token"));
        Object rawTtlMs = Wire.required(object, "ttl_ms");
        builder.ttlMs(Wire.uint64(rawTtlMs, "MintTerminalRendererResult.ttl_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "endpoint", endpoint);
        Wire.put(object, "incarnation", incarnation);
        Wire.put(object, "protocol_version", protocolVersion);
        Wire.put(object, "rights", rights);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "token", token);
        Wire.put(object, "ttl_ms", ttlMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MintTerminalRendererResult that)) return false;
        return Objects.equals(endpoint, that.endpoint) && Objects.equals(incarnation, that.incarnation) && Objects.equals(protocolVersion, that.protocolVersion) && Objects.equals(rights, that.rights) && Objects.equals(terminalId, that.terminalId) && Objects.equals(token, that.token) && Objects.equals(ttlMs, that.ttlMs);
    }

    @Override
    public int hashCode() { return Objects.hash(endpoint, incarnation, protocolVersion, rights, terminalId, token, ttlMs); }

    @Override
    public String toString() { return "MintTerminalRendererResult" + toWire(); }

    public static final class Builder {
        private String endpoint;
        private boolean endpointSet;
        private String incarnation;
        private boolean incarnationSet;
        private Integer protocolVersion;
        private boolean protocolVersionSet;
        private Long rights;
        private boolean rightsSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String token;
        private boolean tokenSet;
        private UInt64 ttlMs;
        private boolean ttlMsSet;

        public Builder endpoint(String value) {
            this.endpoint = value;
            this.endpointSet = true;
            return this;
        }
        public Builder incarnation(String value) {
            this.incarnation = value;
            this.incarnationSet = true;
            return this;
        }
        public Builder protocolVersion(int value) {
            this.protocolVersion = value;
            this.protocolVersionSet = true;
            return this;
        }
        public Builder rights(long value) {
            this.rights = value;
            this.rightsSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder token(String value) {
            this.token = value;
            this.tokenSet = true;
            return this;
        }
        public Builder ttlMs(UInt64 value) {
            this.ttlMs = value;
            this.ttlMsSet = true;
            return this;
        }
        public MintTerminalRendererResult build() { return new MintTerminalRendererResult(this); }
    }
}
