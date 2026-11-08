// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PingResult implements WireValue {
    private final Field<String> buildCommit;
    private final Field<String> ghosttyCommit;
    private final long protocol;
    private final String version;

    private PingResult(Builder builder) {
        this.buildCommit = builder.buildCommit;
        this.ghosttyCommit = builder.ghosttyCommit;
        if (!builder.protocolSet) throw new IllegalArgumentException("protocol is required");
        this.protocol = builder.protocol;
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = Wire.nonNull(builder.version, "version");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> buildCommit() { return buildCommit; }
    public Field<String> ghosttyCommit() { return ghosttyCommit; }
    public Boolean ok() { return true; }
    public long protocol() { return protocol; }
    public String version() { return version; }

    public static PingResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PingResult");
        Builder builder = builder();
        Object rawBuildCommit = Wire.optional(object, "build_commit");
        if (!Wire.isMissing(rawBuildCommit)) {
            builder.buildCommit(rawBuildCommit == null ? null : Wire.string(rawBuildCommit, "PingResult.build_commit"));
        }
        Object rawGhosttyCommit = Wire.optional(object, "ghostty_commit");
        if (!Wire.isMissing(rawGhosttyCommit)) {
            builder.ghosttyCommit(rawGhosttyCommit == null ? null : Wire.string(rawGhosttyCommit, "PingResult.ghostty_commit"));
        }
        Object rawOk = Wire.required(object, "ok");
        ProtocolSupport.literal(rawOk, true, "PingResult.ok");
        Object rawProtocol = Wire.required(object, "protocol");
        builder.protocol(Wire.uint32(rawProtocol, "PingResult.protocol"));
        Object rawVersion = Wire.required(object, "version");
        builder.version(Wire.string(rawVersion, "PingResult.version"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "build_commit", buildCommit);
        Wire.put(object, "ghostty_commit", ghosttyCommit);
        Wire.put(object, "ok", true);
        Wire.put(object, "protocol", protocol);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PingResult that)) return false;
        return Objects.equals(buildCommit, that.buildCommit) && Objects.equals(ghosttyCommit, that.ghosttyCommit) && Objects.equals(protocol, that.protocol) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(buildCommit, ghosttyCommit, protocol, version); }

    @Override
    public String toString() { return "PingResult" + toWire(); }

    public static final class Builder {
        private Field<String> buildCommit = Field.omitted();
        private Field<String> ghosttyCommit = Field.omitted();
        private Long protocol;
        private boolean protocolSet;
        private String version;
        private boolean versionSet;

        public Builder buildCommit(String value) {
            this.buildCommit = Field.ofNullable(value);
            return this;
        }
        public Builder ghosttyCommit(String value) {
            this.ghosttyCommit = Field.ofNullable(value);
            return this;
        }
        public Builder protocol(long value) {
            this.protocol = value;
            this.protocolSet = true;
            return this;
        }
        public Builder version(String value) {
            this.version = value;
            this.versionSet = true;
            return this;
        }
        public PingResult build() { return new PingResult(this); }
    }
}
