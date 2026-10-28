// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemoryTerminals implements WireValue {
    private final UInt64 alternateScreenBytes;
    private final UInt64 bytes;
    private final UInt64 coldHeldBytes;
    private final UInt64 coldTerminals;
    private final UInt64 holderRingBytes;
    private final UInt64 kittyImageBytes;
    private final UInt64 scrollbackCompressedBytes;
    private final UInt64 scrollbackLiveBytes;
    private final UInt64 scrollbackRows;
    private final UInt64 terminals;
    private final List<ServerStatsMemoryTerminal> top;
    private final UInt64 unmeasured;

    private ServerStatsMemoryTerminals(Builder builder) {
        if (!builder.alternateScreenBytesSet) throw new IllegalArgumentException("alternate_screen_bytes is required");
        this.alternateScreenBytes = Wire.nonNull(builder.alternateScreenBytes, "alternate_screen_bytes");
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.coldHeldBytesSet) throw new IllegalArgumentException("cold_held_bytes is required");
        this.coldHeldBytes = Wire.nonNull(builder.coldHeldBytes, "cold_held_bytes");
        if (!builder.coldTerminalsSet) throw new IllegalArgumentException("cold_terminals is required");
        this.coldTerminals = Wire.nonNull(builder.coldTerminals, "cold_terminals");
        if (!builder.holderRingBytesSet) throw new IllegalArgumentException("holder_ring_bytes is required");
        this.holderRingBytes = Wire.nonNull(builder.holderRingBytes, "holder_ring_bytes");
        if (!builder.kittyImageBytesSet) throw new IllegalArgumentException("kitty_image_bytes is required");
        this.kittyImageBytes = Wire.nonNull(builder.kittyImageBytes, "kitty_image_bytes");
        if (!builder.scrollbackCompressedBytesSet) throw new IllegalArgumentException("scrollback_compressed_bytes is required");
        this.scrollbackCompressedBytes = Wire.nonNull(builder.scrollbackCompressedBytes, "scrollback_compressed_bytes");
        if (!builder.scrollbackLiveBytesSet) throw new IllegalArgumentException("scrollback_live_bytes is required");
        this.scrollbackLiveBytes = Wire.nonNull(builder.scrollbackLiveBytes, "scrollback_live_bytes");
        if (!builder.scrollbackRowsSet) throw new IllegalArgumentException("scrollback_rows is required");
        this.scrollbackRows = Wire.nonNull(builder.scrollbackRows, "scrollback_rows");
        if (!builder.terminalsSet) throw new IllegalArgumentException("terminals is required");
        this.terminals = Wire.nonNull(builder.terminals, "terminals");
        if (!builder.topSet) throw new IllegalArgumentException("top is required");
        this.top = List.copyOf(Wire.nonNull(builder.top, "top"));
        if (!builder.unmeasuredSet) throw new IllegalArgumentException("unmeasured is required");
        this.unmeasured = Wire.nonNull(builder.unmeasured, "unmeasured");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 alternateScreenBytes() { return alternateScreenBytes; }
    public UInt64 bytes() { return bytes; }
    public UInt64 coldHeldBytes() { return coldHeldBytes; }
    public UInt64 coldTerminals() { return coldTerminals; }
    public UInt64 holderRingBytes() { return holderRingBytes; }
    public UInt64 kittyImageBytes() { return kittyImageBytes; }
    public UInt64 scrollbackCompressedBytes() { return scrollbackCompressedBytes; }
    public UInt64 scrollbackLiveBytes() { return scrollbackLiveBytes; }
    public UInt64 scrollbackRows() { return scrollbackRows; }
    public UInt64 terminals() { return terminals; }
    public List<ServerStatsMemoryTerminal> top() { return top; }
    public UInt64 unmeasured() { return unmeasured; }

    public static ServerStatsMemoryTerminals fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemoryTerminals");
        Builder builder = builder();
        Object rawAlternateScreenBytes = Wire.required(object, "alternate_screen_bytes");
        builder.alternateScreenBytes(Wire.uint64(rawAlternateScreenBytes, "ServerStatsMemoryTerminals.alternate_screen_bytes"));
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsMemoryTerminals.bytes"));
        Object rawColdHeldBytes = Wire.required(object, "cold_held_bytes");
        builder.coldHeldBytes(Wire.uint64(rawColdHeldBytes, "ServerStatsMemoryTerminals.cold_held_bytes"));
        Object rawColdTerminals = Wire.required(object, "cold_terminals");
        builder.coldTerminals(Wire.uint64(rawColdTerminals, "ServerStatsMemoryTerminals.cold_terminals"));
        Object rawHolderRingBytes = Wire.required(object, "holder_ring_bytes");
        builder.holderRingBytes(Wire.uint64(rawHolderRingBytes, "ServerStatsMemoryTerminals.holder_ring_bytes"));
        Object rawKittyImageBytes = Wire.required(object, "kitty_image_bytes");
        builder.kittyImageBytes(Wire.uint64(rawKittyImageBytes, "ServerStatsMemoryTerminals.kitty_image_bytes"));
        Object rawScrollbackCompressedBytes = Wire.required(object, "scrollback_compressed_bytes");
        builder.scrollbackCompressedBytes(Wire.uint64(rawScrollbackCompressedBytes, "ServerStatsMemoryTerminals.scrollback_compressed_bytes"));
        Object rawScrollbackLiveBytes = Wire.required(object, "scrollback_live_bytes");
        builder.scrollbackLiveBytes(Wire.uint64(rawScrollbackLiveBytes, "ServerStatsMemoryTerminals.scrollback_live_bytes"));
        Object rawScrollbackRows = Wire.required(object, "scrollback_rows");
        builder.scrollbackRows(Wire.uint64(rawScrollbackRows, "ServerStatsMemoryTerminals.scrollback_rows"));
        Object rawTerminals = Wire.required(object, "terminals");
        builder.terminals(Wire.uint64(rawTerminals, "ServerStatsMemoryTerminals.terminals"));
        Object rawTop = Wire.required(object, "top");
        builder.top(Wire.array(rawTop, "ServerStatsMemoryTerminals.top", item -> ServerStatsMemoryTerminal.fromWire(item)));
        Object rawUnmeasured = Wire.required(object, "unmeasured");
        builder.unmeasured(Wire.uint64(rawUnmeasured, "ServerStatsMemoryTerminals.unmeasured"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "alternate_screen_bytes", alternateScreenBytes);
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "cold_held_bytes", coldHeldBytes);
        Wire.put(object, "cold_terminals", coldTerminals);
        Wire.put(object, "holder_ring_bytes", holderRingBytes);
        Wire.put(object, "kitty_image_bytes", kittyImageBytes);
        Wire.put(object, "scrollback_compressed_bytes", scrollbackCompressedBytes);
        Wire.put(object, "scrollback_live_bytes", scrollbackLiveBytes);
        Wire.put(object, "scrollback_rows", scrollbackRows);
        Wire.put(object, "terminals", terminals);
        Wire.put(object, "top", top);
        Wire.put(object, "unmeasured", unmeasured);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemoryTerminals that)) return false;
        return Objects.equals(alternateScreenBytes, that.alternateScreenBytes) && Objects.equals(bytes, that.bytes) && Objects.equals(coldHeldBytes, that.coldHeldBytes) && Objects.equals(coldTerminals, that.coldTerminals) && Objects.equals(holderRingBytes, that.holderRingBytes) && Objects.equals(kittyImageBytes, that.kittyImageBytes) && Objects.equals(scrollbackCompressedBytes, that.scrollbackCompressedBytes) && Objects.equals(scrollbackLiveBytes, that.scrollbackLiveBytes) && Objects.equals(scrollbackRows, that.scrollbackRows) && Objects.equals(terminals, that.terminals) && Objects.equals(top, that.top) && Objects.equals(unmeasured, that.unmeasured);
    }

    @Override
    public int hashCode() { return Objects.hash(alternateScreenBytes, bytes, coldHeldBytes, coldTerminals, holderRingBytes, kittyImageBytes, scrollbackCompressedBytes, scrollbackLiveBytes, scrollbackRows, terminals, top, unmeasured); }

    @Override
    public String toString() { return "ServerStatsMemoryTerminals" + toWire(); }

    public static final class Builder {
        private UInt64 alternateScreenBytes;
        private boolean alternateScreenBytesSet;
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 coldHeldBytes;
        private boolean coldHeldBytesSet;
        private UInt64 coldTerminals;
        private boolean coldTerminalsSet;
        private UInt64 holderRingBytes;
        private boolean holderRingBytesSet;
        private UInt64 kittyImageBytes;
        private boolean kittyImageBytesSet;
        private UInt64 scrollbackCompressedBytes;
        private boolean scrollbackCompressedBytesSet;
        private UInt64 scrollbackLiveBytes;
        private boolean scrollbackLiveBytesSet;
        private UInt64 scrollbackRows;
        private boolean scrollbackRowsSet;
        private UInt64 terminals;
        private boolean terminalsSet;
        private List<ServerStatsMemoryTerminal> top;
        private boolean topSet;
        private UInt64 unmeasured;
        private boolean unmeasuredSet;

        public Builder alternateScreenBytes(UInt64 value) {
            this.alternateScreenBytes = value;
            this.alternateScreenBytesSet = true;
            return this;
        }
        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder coldHeldBytes(UInt64 value) {
            this.coldHeldBytes = value;
            this.coldHeldBytesSet = true;
            return this;
        }
        public Builder coldTerminals(UInt64 value) {
            this.coldTerminals = value;
            this.coldTerminalsSet = true;
            return this;
        }
        public Builder holderRingBytes(UInt64 value) {
            this.holderRingBytes = value;
            this.holderRingBytesSet = true;
            return this;
        }
        public Builder kittyImageBytes(UInt64 value) {
            this.kittyImageBytes = value;
            this.kittyImageBytesSet = true;
            return this;
        }
        public Builder scrollbackCompressedBytes(UInt64 value) {
            this.scrollbackCompressedBytes = value;
            this.scrollbackCompressedBytesSet = true;
            return this;
        }
        public Builder scrollbackLiveBytes(UInt64 value) {
            this.scrollbackLiveBytes = value;
            this.scrollbackLiveBytesSet = true;
            return this;
        }
        public Builder scrollbackRows(UInt64 value) {
            this.scrollbackRows = value;
            this.scrollbackRowsSet = true;
            return this;
        }
        public Builder terminals(UInt64 value) {
            this.terminals = value;
            this.terminalsSet = true;
            return this;
        }
        public Builder top(List<ServerStatsMemoryTerminal> value) {
            this.top = value;
            this.topSet = true;
            return this;
        }
        public Builder unmeasured(UInt64 value) {
            this.unmeasured = value;
            this.unmeasuredSet = true;
            return this;
        }
        public ServerStatsMemoryTerminals build() { return new ServerStatsMemoryTerminals(this); }
    }
}
