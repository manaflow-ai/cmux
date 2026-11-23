// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsCommands implements WireValue {
    private final List<ServerStatsCommandConnections> connections;
    private final List<UInt64> histBoundsNs;
    private final UInt64 nameLimit;
    private final UInt64 names;
    private final List<ServerStatsCommandRow> rows;

    private ServerStatsCommands(Builder builder) {
        if (!builder.connectionsSet) throw new IllegalArgumentException("connections is required");
        this.connections = List.copyOf(Wire.nonNull(builder.connections, "connections"));
        if (!builder.histBoundsNsSet) throw new IllegalArgumentException("hist_bounds_ns is required");
        this.histBoundsNs = List.copyOf(Wire.nonNull(builder.histBoundsNs, "hist_bounds_ns"));
        if (!builder.nameLimitSet) throw new IllegalArgumentException("name_limit is required");
        this.nameLimit = Wire.nonNull(builder.nameLimit, "name_limit");
        if (!builder.namesSet) throw new IllegalArgumentException("names is required");
        this.names = Wire.nonNull(builder.names, "names");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
    }

    public static Builder builder() { return new Builder(); }

    public List<ServerStatsCommandConnections> connections() { return connections; }
    public List<UInt64> histBoundsNs() { return histBoundsNs; }
    public UInt64 nameLimit() { return nameLimit; }
    public UInt64 names() { return names; }
    public List<ServerStatsCommandRow> rows() { return rows; }

    public static ServerStatsCommands fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsCommands");
        Builder builder = builder();
        Object rawConnections = Wire.required(object, "connections");
        builder.connections(Wire.array(rawConnections, "ServerStatsCommands.connections", item -> ServerStatsCommandConnections.fromWire(item)));
        Object rawHistBoundsNs = Wire.required(object, "hist_bounds_ns");
        builder.histBoundsNs(Wire.array(rawHistBoundsNs, "ServerStatsCommands.hist_bounds_ns", item -> Wire.uint64(item, "ServerStatsCommands.hist_bounds_ns item")));
        Object rawNameLimit = Wire.required(object, "name_limit");
        builder.nameLimit(Wire.uint64(rawNameLimit, "ServerStatsCommands.name_limit"));
        Object rawNames = Wire.required(object, "names");
        builder.names(Wire.uint64(rawNames, "ServerStatsCommands.names"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "ServerStatsCommands.rows", item -> ServerStatsCommandRow.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "connections", connections);
        Wire.put(object, "hist_bounds_ns", histBoundsNs);
        Wire.put(object, "name_limit", nameLimit);
        Wire.put(object, "names", names);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsCommands that)) return false;
        return Objects.equals(connections, that.connections) && Objects.equals(histBoundsNs, that.histBoundsNs) && Objects.equals(nameLimit, that.nameLimit) && Objects.equals(names, that.names) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(connections, histBoundsNs, nameLimit, names, rows); }

    @Override
    public String toString() { return "ServerStatsCommands" + toWire(); }

    public static final class Builder {
        private List<ServerStatsCommandConnections> connections;
        private boolean connectionsSet;
        private List<UInt64> histBoundsNs;
        private boolean histBoundsNsSet;
        private UInt64 nameLimit;
        private boolean nameLimitSet;
        private UInt64 names;
        private boolean namesSet;
        private List<ServerStatsCommandRow> rows;
        private boolean rowsSet;

        public Builder connections(List<ServerStatsCommandConnections> value) {
            this.connections = value;
            this.connectionsSet = true;
            return this;
        }
        public Builder histBoundsNs(List<UInt64> value) {
            this.histBoundsNs = value;
            this.histBoundsNsSet = true;
            return this;
        }
        public Builder nameLimit(UInt64 value) {
            this.nameLimit = value;
            this.nameLimitSet = true;
            return this;
        }
        public Builder names(UInt64 value) {
            this.names = value;
            this.namesSet = true;
            return this;
        }
        public Builder rows(List<ServerStatsCommandRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public ServerStatsCommands build() { return new ServerStatsCommands(this); }
    }
}
