// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum TerminalHostLostReason implements WireEnum {
    MISSING_RECORD("missing_record"),
    INCARNATION_MISMATCH("incarnation_mismatch"),
    DEAD_BEFORE_ADOPTION("dead_before_adoption"),
    DIED_DURING_ADOPTION("died_during_adoption"),
    DIED_WITHOUT_EXIT_STATUS("died_without_exit_status"),
    MISSING_EXIT_RECEIPT("missing_exit_receipt"),
    UNADOPTABLE_HOST_ENDED("unadoptable_host_ended"),
    OWNER_GONE("owner_gone"),
    SESSION_SHUTDOWN("session_shutdown"),
    RESTART_EXHAUSTED("restart_exhausted"),
    RESTART_FAILED("restart_failed"),
    OTHER("other");

    private final Object wireValue;

    TerminalHostLostReason(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static TerminalHostLostReason fromWire(Object value) {
        for (TerminalHostLostReason candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown TerminalHostLostReason value " + value, null);
    }
}
