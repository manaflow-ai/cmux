// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientHelloPageOperations implements WireValue {
    private final List<String> confirm;
    private final List<String> gesture;
    private final List<String> read;

    private ClientHelloPageOperations(Builder builder) {
        if (!builder.confirmSet) throw new IllegalArgumentException("confirm is required");
        this.confirm = List.copyOf(Wire.nonNull(builder.confirm, "confirm"));
        if (!builder.gestureSet) throw new IllegalArgumentException("gesture is required");
        this.gesture = List.copyOf(Wire.nonNull(builder.gesture, "gesture"));
        if (!builder.readSet) throw new IllegalArgumentException("read is required");
        this.read = List.copyOf(Wire.nonNull(builder.read, "read"));
    }

    public static Builder builder() { return new Builder(); }

    public List<String> confirm() { return confirm; }
    public List<String> gesture() { return gesture; }
    public List<String> read() { return read; }

    public static ClientHelloPageOperations fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientHelloPageOperations");
        Builder builder = builder();
        Object rawConfirm = Wire.required(object, "confirm");
        builder.confirm(Wire.array(rawConfirm, "ClientHelloPageOperations.confirm", item -> Wire.string(item, "ClientHelloPageOperations.confirm item")));
        Object rawGesture = Wire.required(object, "gesture");
        builder.gesture(Wire.array(rawGesture, "ClientHelloPageOperations.gesture", item -> Wire.string(item, "ClientHelloPageOperations.gesture item")));
        Object rawRead = Wire.required(object, "read");
        builder.read(Wire.array(rawRead, "ClientHelloPageOperations.read", item -> Wire.string(item, "ClientHelloPageOperations.read item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "confirm", confirm);
        Wire.put(object, "gesture", gesture);
        Wire.put(object, "read", read);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientHelloPageOperations that)) return false;
        return Objects.equals(confirm, that.confirm) && Objects.equals(gesture, that.gesture) && Objects.equals(read, that.read);
    }

    @Override
    public int hashCode() { return Objects.hash(confirm, gesture, read); }

    @Override
    public String toString() { return "ClientHelloPageOperations" + toWire(); }

    public static final class Builder {
        private List<String> confirm;
        private boolean confirmSet;
        private List<String> gesture;
        private boolean gestureSet;
        private List<String> read;
        private boolean readSet;

        public Builder confirm(List<String> value) {
            this.confirm = value;
            this.confirmSet = true;
            return this;
        }
        public Builder gesture(List<String> value) {
            this.gesture = value;
            this.gestureSet = true;
            return this;
        }
        public Builder read(List<String> value) {
            this.read = value;
            this.readSet = true;
            return this;
        }
        public ClientHelloPageOperations build() { return new ClientHelloPageOperations(this); }
    }
}
