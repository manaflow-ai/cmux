// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class AgentInventoryWatchResult implements WireValue {
    public enum Kind { AGENT_INVENTORY_WATCH_ACTIVE, EMPTY_RESULT }
    private final Kind kind;
    private final Object value;
    private AgentInventoryWatchResult(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static AgentInventoryWatchResult ofAgentInventoryWatchActive(AgentInventoryWatchActive value) {
        return new AgentInventoryWatchResult(Kind.AGENT_INVENTORY_WATCH_ACTIVE, value);
    }
    public boolean isAgentInventoryWatchActive() { return kind == Kind.AGENT_INVENTORY_WATCH_ACTIVE; }
    public AgentInventoryWatchActive agentInventoryWatchActive() {
        if (!isAgentInventoryWatchActive()) throw new IllegalStateException("AgentInventoryWatchResult contains " + kind);
        return (AgentInventoryWatchActive) value;
    }

    public static AgentInventoryWatchResult ofEmptyResult(EmptyResult value) {
        return new AgentInventoryWatchResult(Kind.EMPTY_RESULT, value);
    }
    public boolean isEmptyResult() { return kind == Kind.EMPTY_RESULT; }
    public EmptyResult emptyResult() {
        if (!isEmptyResult()) throw new IllegalStateException("AgentInventoryWatchResult contains " + kind);
        return (EmptyResult) value;
    }

    public static AgentInventoryWatchResult fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofAgentInventoryWatchActive(AgentInventoryWatchActive.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofEmptyResult(EmptyResult.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no AgentInventoryWatchResult variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof AgentInventoryWatchResult that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "AgentInventoryWatchResult[" + value + "]"; }
}
