package com.cmux;

public enum TopologyResnapshotReason {
    STALE_DAEMON("stale-daemon"), STALE_SESSION("stale-session"),
    REVISION_AHEAD("revision-ahead"), HISTORY_GAP("history-gap"),
    REPLAY_TOO_LARGE("replay-too-large"), SLOW_CONSUMER("slow-consumer");

    private final String wire;
    TopologyResnapshotReason(String wire) { this.wire = wire; }
    public String wire() { return wire; }

    static TopologyResnapshotReason from(String wire) {
        for (TopologyResnapshotReason value : values()) if (value.wire.equals(wire)) return value;
        throw new IllegalArgumentException("invalid topology resnapshot reason " + wire);
    }
}
