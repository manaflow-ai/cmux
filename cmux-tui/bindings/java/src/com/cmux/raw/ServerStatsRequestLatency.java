// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRequestLatency implements WireValue {
    private final ServerStatsHistogram agent;
    private final ServerStatsHistogram browser;
    private final ServerStatsHistogram cloud;
    private final ServerStatsHistogram create;
    private final ServerStatsHistogram other;
    private final ServerStatsHistogram query;
    private final ServerStatsHistogram terminalIo;
    private final ServerStatsHistogram topology;

    private ServerStatsRequestLatency(Builder builder) {
        if (!builder.agentSet) throw new IllegalArgumentException("agent is required");
        this.agent = Wire.nonNull(builder.agent, "agent");
        if (!builder.browserSet) throw new IllegalArgumentException("browser is required");
        this.browser = Wire.nonNull(builder.browser, "browser");
        if (!builder.cloudSet) throw new IllegalArgumentException("cloud is required");
        this.cloud = Wire.nonNull(builder.cloud, "cloud");
        if (!builder.createSet) throw new IllegalArgumentException("create is required");
        this.create = Wire.nonNull(builder.create, "create");
        if (!builder.otherSet) throw new IllegalArgumentException("other is required");
        this.other = Wire.nonNull(builder.other, "other");
        if (!builder.querySet) throw new IllegalArgumentException("query is required");
        this.query = Wire.nonNull(builder.query, "query");
        if (!builder.terminalIoSet) throw new IllegalArgumentException("terminal_io is required");
        this.terminalIo = Wire.nonNull(builder.terminalIo, "terminal_io");
        if (!builder.topologySet) throw new IllegalArgumentException("topology is required");
        this.topology = Wire.nonNull(builder.topology, "topology");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsHistogram agent() { return agent; }
    public ServerStatsHistogram browser() { return browser; }
    public ServerStatsHistogram cloud() { return cloud; }
    public ServerStatsHistogram create() { return create; }
    public ServerStatsHistogram other() { return other; }
    public ServerStatsHistogram query() { return query; }
    public ServerStatsHistogram terminalIo() { return terminalIo; }
    public ServerStatsHistogram topology() { return topology; }

    public static ServerStatsRequestLatency fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRequestLatency");
        Builder builder = builder();
        Object rawAgent = Wire.required(object, "agent");
        builder.agent(ServerStatsHistogram.fromWire(rawAgent));
        Object rawBrowser = Wire.required(object, "browser");
        builder.browser(ServerStatsHistogram.fromWire(rawBrowser));
        Object rawCloud = Wire.required(object, "cloud");
        builder.cloud(ServerStatsHistogram.fromWire(rawCloud));
        Object rawCreate = Wire.required(object, "create");
        builder.create(ServerStatsHistogram.fromWire(rawCreate));
        Object rawOther = Wire.required(object, "other");
        builder.other(ServerStatsHistogram.fromWire(rawOther));
        Object rawQuery = Wire.required(object, "query");
        builder.query(ServerStatsHistogram.fromWire(rawQuery));
        Object rawTerminalIo = Wire.required(object, "terminal_io");
        builder.terminalIo(ServerStatsHistogram.fromWire(rawTerminalIo));
        Object rawTopology = Wire.required(object, "topology");
        builder.topology(ServerStatsHistogram.fromWire(rawTopology));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent", agent);
        Wire.put(object, "browser", browser);
        Wire.put(object, "cloud", cloud);
        Wire.put(object, "create", create);
        Wire.put(object, "other", other);
        Wire.put(object, "query", query);
        Wire.put(object, "terminal_io", terminalIo);
        Wire.put(object, "topology", topology);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRequestLatency that)) return false;
        return Objects.equals(agent, that.agent) && Objects.equals(browser, that.browser) && Objects.equals(cloud, that.cloud) && Objects.equals(create, that.create) && Objects.equals(other, that.other) && Objects.equals(query, that.query) && Objects.equals(terminalIo, that.terminalIo) && Objects.equals(topology, that.topology);
    }

    @Override
    public int hashCode() { return Objects.hash(agent, browser, cloud, create, other, query, terminalIo, topology); }

    @Override
    public String toString() { return "ServerStatsRequestLatency" + toWire(); }

    public static final class Builder {
        private ServerStatsHistogram agent;
        private boolean agentSet;
        private ServerStatsHistogram browser;
        private boolean browserSet;
        private ServerStatsHistogram cloud;
        private boolean cloudSet;
        private ServerStatsHistogram create;
        private boolean createSet;
        private ServerStatsHistogram other;
        private boolean otherSet;
        private ServerStatsHistogram query;
        private boolean querySet;
        private ServerStatsHistogram terminalIo;
        private boolean terminalIoSet;
        private ServerStatsHistogram topology;
        private boolean topologySet;

        public Builder agent(ServerStatsHistogram value) {
            this.agent = value;
            this.agentSet = true;
            return this;
        }
        public Builder browser(ServerStatsHistogram value) {
            this.browser = value;
            this.browserSet = true;
            return this;
        }
        public Builder cloud(ServerStatsHistogram value) {
            this.cloud = value;
            this.cloudSet = true;
            return this;
        }
        public Builder create(ServerStatsHistogram value) {
            this.create = value;
            this.createSet = true;
            return this;
        }
        public Builder other(ServerStatsHistogram value) {
            this.other = value;
            this.otherSet = true;
            return this;
        }
        public Builder query(ServerStatsHistogram value) {
            this.query = value;
            this.querySet = true;
            return this;
        }
        public Builder terminalIo(ServerStatsHistogram value) {
            this.terminalIo = value;
            this.terminalIoSet = true;
            return this;
        }
        public Builder topology(ServerStatsHistogram value) {
            this.topology = value;
            this.topologySet = true;
            return this;
        }
        public ServerStatsRequestLatency build() { return new ServerStatsRequestLatency(this); }
    }
}
