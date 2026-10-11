// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum SnapshotRequestResultStatus implements WireEnum {
    ACCEPTED("accepted"),
    COLLAPSED("collapsed"),
    SNAPSHOT_THROTTLED("snapshot_throttled");

    private final Object wireValue;

    SnapshotRequestResultStatus(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static SnapshotRequestResultStatus fromWire(Object value) {
        for (SnapshotRequestResultStatus candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown SnapshotRequestResultStatus value " + value, null);
    }
}
