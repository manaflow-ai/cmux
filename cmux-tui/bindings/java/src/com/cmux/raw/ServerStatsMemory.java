// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemory implements WireValue {
    private final ServerStatsMemoryJournalRing journalRing;
    private final ServerStatsMemoryOutbound outbound;
    private final ServerStatsMemoryOutputStore outputStore;
    private final ServerStatsMemoryTerminals terminals;

    private ServerStatsMemory(Builder builder) {
        if (!builder.journalRingSet) throw new IllegalArgumentException("journal_ring is required");
        this.journalRing = Wire.nonNull(builder.journalRing, "journal_ring");
        if (!builder.outboundSet) throw new IllegalArgumentException("outbound is required");
        this.outbound = Wire.nonNull(builder.outbound, "outbound");
        if (!builder.outputStoreSet) throw new IllegalArgumentException("output_store is required");
        this.outputStore = Wire.nonNull(builder.outputStore, "output_store");
        if (!builder.terminalsSet) throw new IllegalArgumentException("terminals is required");
        this.terminals = Wire.nonNull(builder.terminals, "terminals");
    }

    public static Builder builder() { return new Builder(); }

    public ServerStatsMemoryJournalRing journalRing() { return journalRing; }
    public ServerStatsMemoryOutbound outbound() { return outbound; }
    public ServerStatsMemoryOutputStore outputStore() { return outputStore; }
    public ServerStatsMemoryTerminals terminals() { return terminals; }

    public static ServerStatsMemory fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemory");
        Builder builder = builder();
        Object rawJournalRing = Wire.required(object, "journal_ring");
        builder.journalRing(ServerStatsMemoryJournalRing.fromWire(rawJournalRing));
        Object rawOutbound = Wire.required(object, "outbound");
        builder.outbound(ServerStatsMemoryOutbound.fromWire(rawOutbound));
        Object rawOutputStore = Wire.required(object, "output_store");
        builder.outputStore(ServerStatsMemoryOutputStore.fromWire(rawOutputStore));
        Object rawTerminals = Wire.required(object, "terminals");
        builder.terminals(ServerStatsMemoryTerminals.fromWire(rawTerminals));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "journal_ring", journalRing);
        Wire.put(object, "outbound", outbound);
        Wire.put(object, "output_store", outputStore);
        Wire.put(object, "terminals", terminals);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemory that)) return false;
        return Objects.equals(journalRing, that.journalRing) && Objects.equals(outbound, that.outbound) && Objects.equals(outputStore, that.outputStore) && Objects.equals(terminals, that.terminals);
    }

    @Override
    public int hashCode() { return Objects.hash(journalRing, outbound, outputStore, terminals); }

    @Override
    public String toString() { return "ServerStatsMemory" + toWire(); }

    public static final class Builder {
        private ServerStatsMemoryJournalRing journalRing;
        private boolean journalRingSet;
        private ServerStatsMemoryOutbound outbound;
        private boolean outboundSet;
        private ServerStatsMemoryOutputStore outputStore;
        private boolean outputStoreSet;
        private ServerStatsMemoryTerminals terminals;
        private boolean terminalsSet;

        public Builder journalRing(ServerStatsMemoryJournalRing value) {
            this.journalRing = value;
            this.journalRingSet = true;
            return this;
        }
        public Builder outbound(ServerStatsMemoryOutbound value) {
            this.outbound = value;
            this.outboundSet = true;
            return this;
        }
        public Builder outputStore(ServerStatsMemoryOutputStore value) {
            this.outputStore = value;
            this.outputStoreSet = true;
            return this;
        }
        public Builder terminals(ServerStatsMemoryTerminals value) {
            this.terminals = value;
            this.terminalsSet = true;
            return this;
        }
        public ServerStatsMemory build() { return new ServerStatsMemory(this); }
    }
}
