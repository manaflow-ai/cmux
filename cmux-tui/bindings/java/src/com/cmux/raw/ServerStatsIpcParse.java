// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcParse implements WireValue {
    private final UInt64 jsonParses;
    private final double jsonParsesPerRequest;
    private final UInt64 requests;

    private ServerStatsIpcParse(Builder builder) {
        if (!builder.jsonParsesSet) throw new IllegalArgumentException("json_parses is required");
        this.jsonParses = Wire.nonNull(builder.jsonParses, "json_parses");
        if (!builder.jsonParsesPerRequestSet) throw new IllegalArgumentException("json_parses_per_request is required");
        this.jsonParsesPerRequest = builder.jsonParsesPerRequest;
        if (!builder.requestsSet) throw new IllegalArgumentException("requests is required");
        this.requests = Wire.nonNull(builder.requests, "requests");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 jsonParses() { return jsonParses; }
    public double jsonParsesPerRequest() { return jsonParsesPerRequest; }
    public UInt64 requests() { return requests; }

    public static ServerStatsIpcParse fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcParse");
        Builder builder = builder();
        Object rawJsonParses = Wire.required(object, "json_parses");
        builder.jsonParses(Wire.uint64(rawJsonParses, "ServerStatsIpcParse.json_parses"));
        Object rawJsonParsesPerRequest = Wire.required(object, "json_parses_per_request");
        builder.jsonParsesPerRequest(Wire.float64(rawJsonParsesPerRequest, "ServerStatsIpcParse.json_parses_per_request"));
        Object rawRequests = Wire.required(object, "requests");
        builder.requests(Wire.uint64(rawRequests, "ServerStatsIpcParse.requests"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "json_parses", jsonParses);
        Wire.put(object, "json_parses_per_request", jsonParsesPerRequest);
        Wire.put(object, "requests", requests);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcParse that)) return false;
        return Objects.equals(jsonParses, that.jsonParses) && Objects.equals(jsonParsesPerRequest, that.jsonParsesPerRequest) && Objects.equals(requests, that.requests);
    }

    @Override
    public int hashCode() { return Objects.hash(jsonParses, jsonParsesPerRequest, requests); }

    @Override
    public String toString() { return "ServerStatsIpcParse" + toWire(); }

    public static final class Builder {
        private UInt64 jsonParses;
        private boolean jsonParsesSet;
        private Double jsonParsesPerRequest;
        private boolean jsonParsesPerRequestSet;
        private UInt64 requests;
        private boolean requestsSet;

        public Builder jsonParses(UInt64 value) {
            this.jsonParses = value;
            this.jsonParsesSet = true;
            return this;
        }
        public Builder jsonParsesPerRequest(double value) {
            this.jsonParsesPerRequest = value;
            this.jsonParsesPerRequestSet = true;
            return this;
        }
        public Builder requests(UInt64 value) {
            this.requests = value;
            this.requestsSet = true;
            return this;
        }
        public ServerStatsIpcParse build() { return new ServerStatsIpcParse(this); }
    }
}
