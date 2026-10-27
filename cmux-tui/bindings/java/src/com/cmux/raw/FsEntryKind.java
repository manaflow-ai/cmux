// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

import java.util.Objects;

public enum FsEntryKind implements WireEnum {
    FILE("file"),
    DIR("dir"),
    SYMLINK("symlink"),
    OTHER("other");

    private final Object wireValue;

    FsEntryKind(Object wireValue) {
        this.wireValue = wireValue;
    }

    @Override
    public String wireValue() {
        return String.valueOf(wireValue);
    }

    public Object rawWireValue() {
        return wireValue;
    }

    public static FsEntryKind fromWire(Object value) {
        for (FsEntryKind candidate : values()) {
            if (Objects.equals(candidate.wireValue, value)
                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {
                return candidate;
            }
        }
        throw new CmuxDecodeException("unknown FsEntryKind value " + value, null);
    }
}
