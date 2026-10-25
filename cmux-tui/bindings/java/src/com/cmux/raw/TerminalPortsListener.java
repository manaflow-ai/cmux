// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalPortsListener implements WireValue {
    /** The loopback address that accepted the daemon's connect: 127.0.0.1 or ::1. */
    private final String bound;
    /** The host as the terminal printed it: localhost, 127.0.0.1, 0.0.0.0, [::1], ... */
    private final String host;
    private final int port;
    /** The printed URL, or http://HOST:PORT/ when the text had no scheme. */
    private final String url;

    private TerminalPortsListener(Builder builder) {
        if (!builder.boundSet) throw new IllegalArgumentException("bound is required");
        this.bound = Wire.nonNull(builder.bound, "bound");
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = Wire.nonNull(builder.host, "host");
        if (!builder.portSet) throw new IllegalArgumentException("port is required");
        this.port = builder.port;
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public String bound() { return bound; }
    public String host() { return host; }
    public int port() { return port; }
    public String url() { return url; }

    public static TerminalPortsListener fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalPortsListener");
        Builder builder = builder();
        Object rawBound = Wire.required(object, "bound");
        builder.bound(Wire.string(rawBound, "TerminalPortsListener.bound"));
        Object rawHost = Wire.required(object, "host");
        builder.host(Wire.string(rawHost, "TerminalPortsListener.host"));
        Object rawPort = Wire.required(object, "port");
        builder.port(Wire.uint16(rawPort, "TerminalPortsListener.port"));
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "TerminalPortsListener.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bound", bound);
        Wire.put(object, "host", host);
        Wire.put(object, "port", port);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalPortsListener that)) return false;
        return Objects.equals(bound, that.bound) && Objects.equals(host, that.host) && Objects.equals(port, that.port) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(bound, host, port, url); }

    @Override
    public String toString() { return "TerminalPortsListener" + toWire(); }

    public static final class Builder {
        private String bound;
        private boolean boundSet;
        private String host;
        private boolean hostSet;
        private Integer port;
        private boolean portSet;
        private String url;
        private boolean urlSet;

        public Builder bound(String value) {
            this.bound = value;
            this.boundSet = true;
            return this;
        }
        public Builder host(String value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder port(int value) {
            this.port = value;
            this.portSet = true;
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public TerminalPortsListener build() { return new TerminalPortsListener(this); }
    }
}
